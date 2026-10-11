"""Create a UTF-8 ZIP with Unix modes; no local xattrs, resource forks, or personal records."""
from pathlib import Path
import sys, zipfile, stat
source = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(source.rglob('*')):
        relative = path.relative_to(source.parent).as_posix()
        if path.is_symlink():
            import os
            info = zipfile.ZipInfo(relative)
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, os.readlink(path))
        elif path.is_file():
            archive.write(path, relative)
