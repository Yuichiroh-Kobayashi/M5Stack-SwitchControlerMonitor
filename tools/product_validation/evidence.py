"""Finalize closed trial artifacts; refuse mutation and escaping paths."""
import hashlib
import json
import os
from pathlib import Path
import zipfile

WORKSPACE = Path(__file__).resolve().parents[2]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def trial_path(path: Path) -> Path:
    root = path.resolve()
    if not root.is_relative_to(WORKSPACE / 'build-temp') or root == WORKSPACE / 'build-temp':
        raise ValueError('Evidence root must be a child of workspace/build-temp')
    return root


def list_files(root: Path) -> list[Path]:
    files = []
    for parent, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            item = Path(parent) / name
            if item.is_symlink() or (getattr(item.stat(), 'st_file_attributes', 0) & 0x400):
                raise ValueError('Reparse points/symlinks are not evidence files')
        files.extend(Path(parent) / name for name in names)
    return sorted(files)


def verify(root: Path) -> dict:
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    actual = {str(f.relative_to(root)).replace('\\', '/') for f in list_files(root) if f != root / 'manifest.json'}
    if actual != set(manifest['files']):
        raise ValueError('Evidence file set changed')
    for name, record in manifest['files'].items():
        file = (root / name).resolve()
        if not file.is_relative_to(root.resolve()) or sha256(file) != record['sha256'] or file.stat().st_size != record['bytes']:
            raise ValueError(f'Evidence hash/size mismatch: {name}')
    return manifest


def finalize(path: Path) -> dict:
    root = trial_path(path)
    archive = root.with_name(root.name + '.zip')
    if not root.is_dir() or (root / 'manifest.json').exists() or archive.exists():
        raise ValueError('Finalization requires an existing, not-yet-finalized trial')
    manifest = {'schema': 'core-trial-evidence-v1', 'files': {
        str(file.relative_to(root)).replace('\\', '/'): {'bytes': file.stat().st_size, 'sha256': sha256(file)}
        for file in list_files(root)}}
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    verify(root)
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as output:
        for file in list_files(root):
            output.write(file, str(file.relative_to(root)).replace('\\', '/'))
    result = {'archive': str(archive), 'sha256': sha256(archive), 'file_count': len(manifest['files'])}
    archive.with_suffix('.zip.sha256').write_text(result['sha256'] + '\n', encoding='ascii')
    return result
