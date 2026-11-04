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
FIXTURE_BEZ_LINII = os.path.join(ROOT, "Tests", "Fixtures", "wyglad-bez-linii.pdf")
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

    def test_podpisz_without_a_driver_writes_nothing(self):
        out = tempfile.mkdtemp(dir=self.td)
        r = subprocess.run([sys.executable, "-I", CLI, "wyglad", "--json", "--podpisz", "--nad", "Jan Kowalski",
                            "--out-dir", out, self.base], capture_output=True, text=True,
                           env={**os.environ, "PODPIS_HOME": self.home,
                                "PODPIS_PKCS11": os.path.join(self.td, "libCloudSignerP11.dylib")})
        res = json.loads(r.stdout)
        self.assertEqual(r.returncode, 2, res)
        self.assertEqual(res["kod"], "brak_sterownika")
        self.assertIn("CloudSigner", res["blad"])
        self.assertEqual(os.listdir(out), [])


class Refused(Exception):
    pass


class WygladPodpisz(unittest.TestCase):
    """`wyglad --podpisz`: the art, then the token's invisible signature over it, in one step. The
    token is stood in for by pyHanko signers with throwaway keys, called in process."""

    @classmethod
    def setUpClass(cls):
        import argparse
        import pkcs11
        from pyhanko.sign import fields, signers
        cls.td = tempfile.mkdtemp(prefix="podpis-wyglad-podpisz-test-")
        P.HOME, P._CONFIG = os.path.join(cls.td, "home"), {}   # the name in a script font, as in Wyglad
        cls.base = os.path.join(cls.td, "umowa.pdf")
        shutil.copyfile(FIXTURE, cls.base)
        cls.jan_signer = make_signer(cls.td, "Jan Kowalski")
        cls.jan = os.path.join(cls.td, "umowa-jan.pdf")
        sign(cls.base, cls.jan, cls.jan_signer, "Signature1", fields.SigSeedSubFilter.ADOBE_PKCS7_DETACHED)

        class RefusingSigner(signers.SimpleSigner):
            async def async_sign_raw(self, data, digest_algorithm, dry_run=False):
                if dry_run:
                    return await super().async_sign_raw(data, digest_algorithm, dry_run)
                raise pkcs11.exceptions.FunctionCancelled()
        cls.refusing = RefusingSigner(cls.jan_signer.signing_cert, cls.jan_signer.signing_key,
                                      cls.jan_signer.cert_registry)
        cls.args = lambda self, **kw: argparse.Namespace(**{"out_dir": None, "strona": None, "bez_cofania": False, **kw})

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.td, ignore_errors=True)

    def run_one(self, src, nad="Jan Kowalski", signer=None):
        out = tempfile.mkdtemp(dir=self.td)
        res = P._wyglad_podpisz_one(src, nad, "15.10.2026", self.args(out_dir=out), signer or self.jan_signer,
                                    "Jan Kowalski")
        return res, out

    def test_art_then_one_signature_over_it(self):
        res, out = self.run_one(self.base)
        self.assertEqual(os.listdir(out), ["umowa.pdf"])   # the signed file only, no -do-podpisu
        data = read(res["plik"])
        self.assertTrue(data.startswith(read(self.base)))
        self.assertEqual([m["strona"] for m in res["miejsca"]], [2, 2, 3])
        self.assertEqual([p for p, _ in stamps(data)], [2, 2, 3])
        rows = P._check_signatures(data)
        self.assertEqual([r["podpisal"] for r in rows], ["Jan Kowalski"])
        self.assertTrue(rows[0]["integralnosc"])
        self.assertEqual(rows[0]["obejmuje"], "ENTIRE_FILE")

    def test_next_to_the_original_with_podpisany(self):
        src = os.path.join(tempfile.mkdtemp(dir=self.td), "aneks.pdf")
        shutil.copyfile(self.base, src)
        res = P._wyglad_podpisz_one(src, "Jan Kowalski", "15.10.2026", self.args(), self.jan_signer, "Jan Kowalski")
        self.assertEqual(res["plik"], os.path.join(os.path.dirname(src), "aneks-podpisany.pdf"))
        self.assertEqual(sorted(os.listdir(os.path.dirname(src))), ["aneks-podpisany.pdf", "aneks.pdf"])

    def test_own_last_signature_cut_and_signed_again(self):
        res, _ = self.run_one(self.jan)
        self.assertEqual(res["cofniety"]["podpisal"], "Jan Kowalski")
        data = read(res["plik"])
        self.assertTrue(data.startswith(read(self.base)))
        rows = P._check_signatures(data)
        self.assertEqual([r["podpisal"] for r in rows], ["Jan Kowalski"])
        self.assertEqual(rows[0]["obejmuje"], "ENTIRE_FILE")
        self.assertEqual(res["uwagi"], [])

    def test_no_signature_line_signs_without_art(self):
        res, _ = self.run_one(self.base, nad="Anna Kowalska")
        data = read(res["plik"])
        self.assertTrue(data.startswith(read(self.base)))
        self.assertEqual(stamps(data), [])
        self.assertEqual(P._check_signatures(data)[0]["obejmuje"], "ENTIRE_FILE")
        self.assertTrue(any("bez nowej grafiki" in u for u in res["uwagi"]))

    def test_refused_on_the_phone_leaves_nothing(self):
        out = tempfile.mkdtemp(dir=self.td)
        with self.assertRaises(P.Blad) as e:
            P._wyglad_podpisz_one(self.base, "Jan Kowalski", "15.10.2026", self.args(out_dir=out), self.refusing,
                                  "Jan Kowalski")
        self.assertEqual(e.exception.kod, "podpis")
        self.assertEqual(os.listdir(out), [])

    def test_block_without_a_line_gets_the_art_and_the_text_does_not(self):
        res = P._wyglad_one(FIXTURE_BEZ_LINII, "Jan Kowalski", "15.10.2026",
                            self.args(out_dir=tempfile.mkdtemp(dir=self.td)))
        self.assertEqual([m["strona"] for m in res["miejsca"]], [1, 1])
        # the subtitle, the text and the address above the street: no art
        self.assertEqual(sum(s["powod"].startswith("nazwisko w treści") for s in res["pominiete"]), 3)
        page = P._words(FIXTURE_BEZ_LINII)[0]
        names = sorted(P._name_hits(page["words"], "Jan Kowalski"), key=lambda n: n[1])
        self.assertEqual(len(names), 5)
        arts = sorted(res["miejsca"], key=lambda m: -m["rect"][3])   # top first
        for art, name in zip(arts, names[-2:]):   # the block with the line, then the one without
            bottom = page["h"] - art["rect"][1]
            self.assertLessEqual(bottom, name[1], "the art ends above the name")
            self.assertGreater(bottom, name[1] - 16, "and close to it")
            self.assertTrue(art["rect"][0] < name[2] and art["rect"][2] > name[0], "over the name")
            self.assertEqual(art["skala"], 1.0)

    def test_a_place_with_art_is_skipped_not_its_page(self):
        data = read(FIXTURE_BEZ_LINII)
        slots, _ = P._signature_lines(FIXTURE_BEZ_LINII, "Jan Kowalski", None, P._pages_meta(data))
        upper = max(slots, key=lambda s: s["rect"][3])   # the block with the line
        with tempfile.TemporaryDirectory() as td:
            half = P._add_art(data, [upper], "15.10.2026", "Jan Kowalski", td)
        src = os.path.join(tempfile.mkdtemp(dir=self.td), "polowa.pdf")
        with open(src, "wb") as f:
            f.write(half)
        res = P._wyglad_one(src, "Jan Kowalski", "16.10.2026", self.args(out_dir=tempfile.mkdtemp(dir=self.td)))
        self.assertEqual(len(res["miejsca"]), 1)
        self.assertLess(res["miejsca"][0]["rect"][3], upper["rect"][1], "the block without the line, lower down")
        self.assertIn("już ma grafikę podpisu z wyglad", [s["powod"] for s in res["pominiete"]])
        self.assertEqual(len(stamps(read(res["plik"]))), 2)

    def test_every_place_with_art_signed_again_not_twice(self):
        first, _ = self.run_one(FIXTURE_BEZ_LINII)
        res, _ = self.run_one(first["plik"])
        self.assertEqual(res["cofniety"]["podpisal"], "Jan Kowalski")
        self.assertEqual(res["miejsca"], [])
        self.assertTrue(any("ma już grafikę" in u for u in res["uwagi"]), res["uwagi"])
        data = read(res["plik"])
        self.assertTrue(data.startswith(read(FIXTURE_BEZ_LINII)))
        rows = P._check_signatures(data)
        self.assertEqual([r["podpisal"] for r in rows], ["Jan Kowalski"])
        self.assertEqual(rows[0]["obejmuje"], "ENTIRE_FILE")
        self.assertEqual(len(stamps(data)), 2)

    def test_visible_signature_of_pdf_still_in_its_box(self):
        """`podpisz pdf` goes through the same _sign_pdf, with a rect."""
        from pyhanko.pdf_utils.reader import PdfFileReader
        place = P._place(self.base, "Anna Nowak")   # the line Podpis.app would sign on
        out = os.path.join(tempfile.mkdtemp(dir=self.td), "widoczny.pdf")
        P._sign_pdf(self.base, out, self.jan_signer, "Jan Kowalski", place["strona"], place["rect"])
        data = read(out)
        self.assertTrue(data.startswith(read(self.base)))
        sig = PdfFileReader(BytesIO(data), strict=False).embedded_signatures[0]
        rect = [float(v) for v in sig.sig_field["/Rect"]]
        self.assertEqual(rect, [float(int(round(v))) for v in place["rect"]])
        self.assertEqual(P._check_signatures(data)[0]["obejmuje"], "ENTIRE_FILE")


if __name__ == "__main__":
    unittest.main()
