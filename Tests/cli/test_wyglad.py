"""`podpisz wyglad`: the art on the signer's lines before another tool signs.

    ~/.local/share/podpis/venv/bin/python -m unittest discover -s Tests/cli -v

No card: the earlier signatures come from pyHanko with throwaway self-signed keys (openssl). The
CLI runs as a child process, like the app runs it, with an empty PODPIS_HOME (the name is set in a
script font). Needs what the CLI needs: poppler and Chrome, Chromium, Brave or Edge.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from io import BytesIO

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLI = os.path.join(ROOT, "cli", "podpisz.py")
FIXTURE = os.path.join(ROOT, "Tests", "Fixtures", "wyglad-blok.pdf")
sys.path.insert(0, os.path.join(ROOT, "cli"))
import podpisz as P  # noqa: E402


def make_signer(workdir, cn):
    from pyhanko.sign import signers
    key, crt = os.path.join(workdir, f"{cn}.key"), os.path.join(workdir, f"{cn}.crt")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", f"/CN={cn}",
                    "-keyout", key, "-out", crt], check=True, capture_output=True)
    return signers.SimpleSigner.load(key, crt)


def sign(src, dst, who, field, subfilter, page=None, box=None):
    """A signature of `who` appended to `src`: visible in its own field, or invisible like iText's."""
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
    from pyhanko.sign import fields, signers
    with open(src, "rb") as f:
        w = IncrementalPdfFileWriter(BytesIO(f.read()), strict=False)
    if box:
        fields.append_signature_field(w, fields.SigFieldSpec(sig_field_name=field, on_page=page - 1, box=box))
    meta = signers.PdfSignatureMetadata(field_name=field, md_algorithm="sha256", subfilter=subfilter)
    with open(dst, "wb") as out:
        signers.PdfSigner(meta, signer=who).sign_pdf(w, output=out)


def read(path):
    with open(path, "rb") as f:
        return f.read()


def stamps(data):
    """Page number and /F of every /Stamp annotation."""
    from pyhanko.pdf_utils.reader import PdfFileReader
    r = PdfFileReader(BytesIO(data), strict=False)
    out = []
    for i in range(int(r.root["/Pages"]["/Count"])):
        page_ref, _ = r.find_page_for_modification(i)
        for a in page_ref.get_object().get("/Annots", []) or []:
            a = a.get_object()
            if a.get("/Subtype") == "/Stamp":
                out.append((i + 1, int(a["/F"])))
    return out


class Wyglad(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from pyhanko.sign import fields
        cls.td = tempfile.mkdtemp(prefix="podpis-wyglad-test-")
        cls.home = os.path.join(cls.td, "home")
        os.makedirs(cls.home)
        cls.base = os.path.join(cls.td, "umowa.pdf")
        shutil.copyfile(FIXTURE, cls.base)
        # Anna signs first, visibly, where the app would put her signature (like Filip with Podpis)
        cls.anna = os.path.join(cls.td, "umowa-anna.pdf")
        place = P._place(cls.base, "Anna Nowak")
        sign(cls.base, cls.anna, make_signer(cls.td, "Anna Nowak"), "Podpis_Anna_Nowak",
             fields.SigSeedSubFilter.PADES, place["strona"], tuple(place["rect"]))
        # then Jan, invisibly, the way an iText tool does (field Signature1, adbe.pkcs7.detached)
        cls.jan_signer = make_signer(cls.td, "Jan Kowalski")
        cls.jan = os.path.join(cls.td, "umowa-anna-jan.pdf")
        sign(cls.anna, cls.jan, cls.jan_signer, "Signature1", fields.SigSeedSubFilter.ADOBE_PKCS7_DETACHED)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.td, ignore_errors=True)

    def wyglad(self, *args):
        out = tempfile.mkdtemp(dir=self.td)
        r = subprocess.run([sys.executable, "-I", CLI, "wyglad", "--json", "--nad", "Jan Kowalski", "--data", "15.10.2026",
                            "--out-dir", out, *args], capture_output=True, text=True,
                           env={**os.environ, "PODPIS_HOME": self.home})
        res = json.loads(r.stdout)
        return res, r.returncode

    def test_art_on_every_signature_line_with_annexes_not_in_text(self):
        res, code = self.wyglad(self.base)
        self.assertEqual(code, 0, res)
        f = res["pliki"][0]
        self.assertEqual([m["strona"] for m in f["miejsca"]], [2, 2, 3])
        reasons = {(s["strona"], s["powod"].split(" (")[0]) for s in f["pominiete"]}
        self.assertIn((1, "nazwisko w treści"), reasons)
        self.assertIn((2, "nazwisko w treści"), reasons)   # the table's header cell: a drawn line, other cells before
        page = P._words(FIXTURE)[1]
        names = sorted(P._name_hits(page["words"], "Jan Kowalski"), key=lambda n: n[1])
        self.assertEqual(len(names), 3)
        names = names[1:]   # the table's header comes first, then the two signature lines
        arts = sorted((m for m in f["miejsca"] if m["strona"] == 2), key=lambda m: -m["rect"][3])   # top first
        for art, name in zip(arts, names):
            x1, y1, x2, y2 = art["rect"]
            bottom = page["h"] - y1
            self.assertLessEqual(bottom, name[1], "the art ends above the name")
            self.assertGreater(bottom, name[1] - 16, "and close to it: on the signature line")
            self.assertTrue(x1 < name[2] and x2 > name[0], "over the name, not beside it")
        # the drawn line has a seal printed over its right end: the art there is drawn smaller
        self.assertLess(arts[0]["skala"], 1.0)
        self.assertEqual(arts[1]["skala"], 1.0)
        data = read(f["plik"])
        self.assertTrue(data.startswith(read(self.base)))
        self.assertEqual(stamps(data), [(2, 4 | 64 | 128 | 512), (2, 4 | 64 | 128 | 512), (3, 4 | 64 | 128 | 512)])

    def test_strona_keeps_the_art_to_one_page(self):
        res, code = self.wyglad(self.base, "--strona", "3")
        self.assertEqual(code, 0, res)
        f = res["pliki"][0]
        self.assertEqual([m["strona"] for m in f["miejsca"]], [3])
        self.assertIn((2, "inna strona niż --strona"), {(s["strona"], s["powod"]) for s in f["pominiete"]})
        self.assertEqual(stamps(read(f["plik"])), [(3, 4 | 64 | 128 | 512)])

    def test_cuts_the_signers_own_last_signature_byte_exact(self):
        res, code = self.wyglad(self.jan)
        self.assertEqual(code, 0, res)
        f = res["pliki"][0]
        anna = read(self.anna)
        self.assertEqual(f["cofniety"]["podpisal"], "Jan Kowalski")
        self.assertEqual(f["cofniety"]["bajty_po"], len(anna))
        self.assertEqual(f["cofniety"]["sha256_po"], hashlib.sha256(anna).hexdigest())
        self.assertTrue(read(f["plik"]).startswith(anna))
        self.assertEqual([p["podpisal"] for p in f["podpisy"]], ["Anna Nowak"])

    def test_earlier_signature_intact_and_only_the_art_after_it(self):
        res, _ = self.wyglad(self.jan)
        anna = res["pliki"][0]["podpisy"][0]
        self.assertTrue(anna["integralnosc"])
        self.assertEqual(anna["zmiany_po_wyglad"], "ANNOTATIONS")
        # pyHanko's default policy has no rule for annotations: any of them is OTHER there
        self.assertEqual(anna["zmiany_po"], "OTHER")

    def test_never_cuts_someone_elses_signature(self):
        res, code = self.wyglad(self.anna)
        self.assertEqual(code, 0, res)
        f = res["pliki"][0]
        self.assertIsNone(f["cofniety"])
        self.assertTrue(read(f["plik"]).startswith(read(self.anna)))

    def test_bez_cofania_keeps_the_signature_and_says_it_no_longer_covers_the_file(self):
        res, code = self.wyglad("--bez-cofania", self.jan)
        self.assertEqual(code, 0, res)
        f = res["pliki"][0]
        self.assertIsNone(f["cofniety"])
        self.assertTrue(read(f["plik"]).startswith(read(self.jan)))
        self.assertNotEqual(f["podpisy"][-1]["obejmuje"], "ENTIRE_FILE")
        self.assertTrue(f["uwagi"])

    def test_signing_after_the_art_covers_it(self):
        from pyhanko.sign import fields
        res, _ = self.wyglad(self.jan)
        out = res["pliki"][0]["plik"]
        signed = os.path.join(self.td, "po-wygladzie-podpisany.pdf")
        sign(out, signed, self.jan_signer, "Signature1", fields.SigSeedSubFilter.ADOBE_PKCS7_DETACHED)
        rows = P._check_signatures(read(signed))
        self.assertEqual([r["podpisal"] for r in rows], ["Anna Nowak", "Jan Kowalski"])
        self.assertTrue(all(r["integralnosc"] for r in rows))
        self.assertEqual(rows[-1]["obejmuje"], "ENTIRE_FILE")
        self.assertEqual(rows[0]["zmiany_po_wyglad"], "ANNOTATIONS")

    def test_stamp_rule_clears_nothing_but_stamps(self):
        from pyhanko.pdf_utils import generic
        from pyhanko.pdf_utils.generic import pdf_name, pdf_string
        from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
        res, _ = self.wyglad(self.jan)
        art = read(res["pliki"][0]["plik"])
        # a comment (FreeText) instead of a stamp
        w = IncrementalPdfFileWriter(BytesIO(art), strict=False)
        page_ref, _ = w.find_page_for_modification(1)
        note = generic.DictionaryObject({
            pdf_name("/Type"): pdf_name("/Annot"), pdf_name("/Subtype"): pdf_name("/FreeText"),
            pdf_name("/Rect"): generic.ArrayObject([generic.FloatObject(v) for v in (300, 300, 400, 320)]),
            pdf_name("/Contents"): pdf_string("dopisek"), pdf_name("/DA"): pdf_string("/Helv 10 Tf 0 g")})
        w.register_annotation(page_ref, w.add_object(note))
        buf = BytesIO()
        w.write(buf)
        self.assertEqual(P._check_signatures(buf.getvalue())[0]["zmiany_po_wyglad"], "OTHER")
        # new page content next to a stamp
        w = IncrementalPdfFileWriter(BytesIO(art), strict=False)
        w.add_stream_to_page(1, w.add_object(generic.StreamObject(stream_data=b"0 0 m 200 200 l S")))
        buf = BytesIO()
        w.write(buf)
        self.assertEqual(P._check_signatures(buf.getvalue())[0]["zmiany_po_wyglad"], "OTHER")

    def test_input_untouched_and_never_overwritten(self):
        before = read(self.jan)
        res, _ = self.wyglad(self.jan)
        self.assertEqual(read(self.jan), before)
        r = subprocess.run([sys.executable, "-I", CLI, "wyglad", "--json", "--nad", "Jan Kowalski",
                            "--out-dir", os.path.dirname(self.jan), self.jan], capture_output=True, text=True,
                           env={**os.environ, "PODPIS_HOME": self.home})
        res = json.loads(r.stdout)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(res["pliki"][0]["kod"], "nadpisanie")
        self.assertEqual(read(self.jan), before)

    def test_no_line_no_art(self):
        res, code = self.wyglad("--nad", "Anna Kowalska", self.base)
        self.assertEqual(code, 1)
        self.assertEqual(res["pliki"][0]["kod"], "brak_linii")


if __name__ == "__main__":
    unittest.main()
