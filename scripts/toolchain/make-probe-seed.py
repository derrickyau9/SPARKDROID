"""Create the isolated GPU probe NoCloud seed without modifying the runtime seed."""
import io
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "tools" / "python-libs"))
import pycdlib

seed = root / "state" / "gpu-probe-seed"
output = root / "state" / "gpu-probe-seed.iso"
iso = pycdlib.PyCdlib()
iso.new(interchange_level=3, joliet=3, rock_ridge="1.09", vol_ident="cidata")
for name, iso_name in [("user-data", "USER_DATA.;1"), ("meta-data", "META_DATA.;1")]:
    data = (seed / name).read_bytes()
    iso.add_fp(io.BytesIO(data), len(data), iso_path="/" + iso_name,
               rr_name=name, joliet_path="/" + name)
iso.write(str(output))
iso.close()
print(output)
