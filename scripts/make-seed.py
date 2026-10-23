"""Create a local NoCloud CD-ROM. No administrator privileges needed."""
import io
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tools" / "python-libs"))
import pycdlib

seed = root / "state" / "seed"
iso = pycdlib.PyCdlib()
iso.new(interchange_level=3, joliet=3, rock_ridge="1.09", vol_ident="cidata")
for name, iso_name in [("user-data", "USER_DATA.;1"), ("meta-data", "META_DATA.;1")]:
    content = (seed / name).read_bytes()
    iso.add_fp(io.BytesIO(content), len(content), iso_path="/" + iso_name,
               rr_name=name, joliet_path="/" + name)
iso.write(str(root / "state" / "seed.iso"))
iso.close()
print(root / "state" / "seed.iso")
