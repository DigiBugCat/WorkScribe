import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
import tarfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime_home as runtime
spec = importlib.util.spec_from_file_location('doctor', Path(__file__).resolve().parents[1] / 'runtime-doctor.py')
doctor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doctor)

class RuntimeTests(unittest.TestCase):
    def test_dataless_does_not_hash(self):
        with patch.object(runtime, 'sha256', side_effect=AssertionError('opened placeholder')):
            self.assertEqual(runtime.state('/fixture', 'hash', lambda _: SimpleNamespace(st_flags=runtime.DATALESS, st_size=5700000000)), 'evicted')

    def test_recursive_empty_and_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.assertEqual(runtime.state(root), 'missing')
            (root/'weights').write_bytes(b'abc')
            self.assertEqual(runtime.state(root), 'present')
            self.assertEqual(runtime.state(root/'weights','bad'), 'wrong hash')
            (root/'weights').write_bytes(b'')
            self.assertEqual(runtime.state(root), 'wrong hash')

    def test_doctor_pins_embedding_tables_even_with_compiled_stamp(self):
        entries = {name: digest for name, digest, _ in doctor.specs()}
        self.assertIn('models/embeddinggemma-2-coreml/embeddings.bf16', entries)
        self.assertIn('models/embeddinggemma-2-coreml/tokenizer.json', entries)
        self.assertIn('models/embeddinggemma-2-coreml/position_embeddings.f16', entries)

    def test_same_size_mutation_invalidates_verified_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'model'
            path.write_bytes(b'abc'); expected=runtime.sha256(path)
            self.assertEqual(runtime.state(path,expected),'present')
            path.write_bytes(b'xyz')
            self.assertEqual(runtime.state(path,expected),'wrong hash')

    def test_missing_native_symlink_is_reported(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'existing').write_bytes(b'abc')
            (root/'lib').symlink_to('missing-library')
            self.assertEqual(runtime.state(root), 'missing')

    def test_download_rejects_bad_hash_without_replacing(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'weights'; target.write_bytes(b'old')
            def make_response():
                stream=io.BytesIO(b'bad'); stream.headers={}; stream.status=200
                return stream
            with patch.object(doctor.urllib.request, 'urlopen', return_value=contextlib.closing(io.BytesIO(b'bad'))):
                # A real response supplies headers.
                stream=io.BytesIO(b'bad'); stream.headers={}; stream.status=200
                with patch.object(doctor.urllib.request, 'urlopen', side_effect=lambda *a, **k: make_response()), patch.object(doctor.time, 'sleep'):
                    with self.assertRaises(RuntimeError): doctor.download('https://example.invalid', 'wrong',target)
            self.assertEqual(target.read_bytes(),b'old')
            self.assertFalse(target.with_name('weights.partial').exists())

    def test_failed_coreml_rebuild_preserves_previous_graph(self):
        source = Path(__file__).resolve().parents[1] / 'prepare-embedding-model.py'
        spec = importlib.util.spec_from_file_location('prepare_embedding', source)
        prepare = importlib.util.module_from_spec(spec); spec.loader.exec_module(prepare)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); compiled = root/'Test.mlmodelc'; compiled.mkdir()
            (compiled/'weights').write_bytes(b'previous working graph')
            metadata = {'text': {'revision': 'new', 'package': 'Test', 'files': {}}}
            with patch.object(prepare, 'METADATA', metadata), patch.object(prepare.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'coremlcompiler')):
                with self.assertRaises(subprocess.CalledProcessError): prepare.prepare('text', root)
            self.assertEqual((compiled/'weights').read_bytes(), b'previous working graph')
            self.assertFalse(list(root.glob('.compile-*')))

    def test_complete_partial_is_published_without_network(self):
        import hashlib
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'weights'
            target.with_name('weights.partial').write_bytes(b'abc')
            with patch.object(doctor.urllib.request, 'urlopen', side_effect=AssertionError('download')):
                doctor.download('https://example.invalid', hashlib.sha256(b'abc').hexdigest(), target)
            self.assertEqual(target.read_bytes(), b'abc')

    def test_download_resumes_partial_response(self):
        import hashlib
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'weights'
            target.with_name('weights.partial').write_bytes(b'ab')
            stream = io.BytesIO(b'c'); stream.headers = {}; stream.status = 206
            with patch.object(doctor.urllib.request, 'urlopen', return_value=stream) as fetch:
                doctor.download('https://example.invalid', hashlib.sha256(b'abc').hexdigest(), target)
            self.assertEqual(target.read_bytes(), b'abc')
            self.assertEqual(fetch.call_args.args[0].get_header('Range'), 'bytes=2-')

    def test_download_restarts_when_server_ignores_range(self):
        import hashlib
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'weights'
            target.with_name('weights.partial').write_bytes(b'ab')
            stream = io.BytesIO(b'abc'); stream.headers = {}; stream.status = 200
            with patch.object(doctor.urllib.request, 'urlopen', return_value=stream):
                doctor.download('https://example.invalid', hashlib.sha256(b'abc').hexdigest(), target)
            self.assertEqual(target.read_bytes(), b'abc')

    def test_local_copy_installs_only_with_matching_hash(self):
        import hashlib
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root/'source'; source.mkdir()
            (source/'weights.bin').write_bytes(b'abc')
            with patch.object(doctor, 'HOME', root/'home'), patch.object(doctor, 'download', side_effect=AssertionError('network')):
                doctor.install('models/m/weights.bin', hashlib.sha256(b'abc').hexdigest(), 'https://example.invalid', [source])
            self.assertEqual((root/'home/models/m/weights.bin').read_bytes(), b'abc')
            self.assertFalse((root/'home/models/m/weights.bin.partial').exists())
            # A local file with another hash is never installed; the pinned download is used.
            with patch.object(doctor, 'HOME', root/'other'), patch.object(doctor, 'download') as fetch:
                doctor.install('models/m/weights.bin', hashlib.sha256(b'xyz').hexdigest(), 'https://example.invalid', [source])
            fetch.assert_called_once()
            self.assertFalse((root/'other/models/m/weights.bin').exists())

    def test_copy_verified_rejects_a_mismatch(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); (root/'a').write_bytes(b'abc'); target = root/'b'
            with self.assertRaises(RuntimeError): doctor.copy_verified(root/'a', 'wrong', target)
            self.assertFalse(target.exists()); self.assertFalse(root.joinpath('b.partial').exists())

    def test_only_product_model_families_are_installed(self):
        entries = {name for name, _, _ in doctor.specs()}
        self.assertIn('models/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf', entries)
        self.assertIn('models/Nemotron-3-Diarization.q8_0.gguf', entries)
        for name in entries:
            self.assertTrue(name in {
                'models/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf',
                'models/Nemotron-3-Diarization.q8_0.gguf',
            } or name.startswith(('models/embeddinggemma-2-coreml/', 'models/wespeaker_v2.mlmodelc/')), name)

    def test_retired_receipts_are_not_product_assets(self):
        for name, _, _ in doctor.specs():
            self.assertTrue(doctor.product_asset(name), name)
        for name in ['models/Qwen3.5-2B-Q4_K_M.gguf', 'models/gemma-4-E2B_q4_0-it.gguf',
                     'models/qwen3-4b-instruct-2507-mlx/model.safetensors', 'speaker/weights',
                     'models/vision/gemma-4-E2B-it-Q4_0.gguf', 'unrelated/data',
                     'models/gemma-4-E4B-it-Q4_0.gguf', 'models/vision/mmproj-gemma-4-E4B-it-Q8_0.gguf',
                     'models/vision/bin/image-caption', 'models/vision/lib/libllama.dylib']:
            self.assertFalse(doctor.product_asset(name), name)

    def retired_home(self, root):
        """A runtime home that still holds the retired text model and image helper beside other files."""
        home = root/'home'
        (home/'models/vision/bin').mkdir(parents=True); (home/'models/vision/lib').mkdir()
        (home/'models/gemma-4-E4B-it-Q4_0.gguf').write_bytes(b'text model')
        (home/'models/gemma-4-E4B-it-Q4_0.gguf.partial').write_bytes(b'half a download')
        (home/'models/vision/mmproj-gemma-4-E4B-it-Q8_0.gguf').write_bytes(b'projector')
        (home/'models/vision/bin/image-caption').write_bytes(b'helper')
        (home/'models/vision/lib/libllama.dylib').write_bytes(b'library')
        (home/'models/Qwen3.5-2B-Q4_K_M.gguf').write_bytes(b'older model')
        (home/'models/Nemotron-3-Diarization.q8_0.gguf').write_bytes(b'speech model')
        return home

    def test_a_plain_repair_keeps_retired_files_another_checkout_may_still_use(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); home = self.retired_home(root)
            with patch.object(doctor, 'HOME', home), patch.object(doctor, 'CACHE', root/'cache'), \
                    patch.object(doctor, 'ROOT', root/'checkout'), \
                    patch.dict(os.environ, {'WORKSCRIBE_MIGRATE_LEGACY': '0'}), \
                    patch.object(sys, 'argv', ['doctor']), \
                    patch.object(doctor, 'install_nemo', side_effect=RuntimeError('offline')), \
                    patch.object(doctor, 'install', side_effect=RuntimeError('offline')), \
                    patch.object(doctor.subprocess, 'run', side_effect=RuntimeError('offline')), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                doctor.main()
            self.assertEqual((home/'models/gemma-4-E4B-it-Q4_0.gguf').read_bytes(), b'text model')
            self.assertEqual((home/'models/vision/bin/image-caption').read_bytes(), b'helper')
            self.assertIn('--remove-retired', output.getvalue())

    def test_remove_retired_deletes_the_text_model_and_image_helper_when_asked(self):
        import json
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); home = self.retired_home(root)
            (home/'checksums.json').write_text(json.dumps({
                'models/gemma-4-E4B-it-Q4_0.gguf': 'old', 'models/vision/bin/image-caption': 'old'}))
            # A whole repair run, offline: ROOT is moved so nothing is written into the checkout.
            with patch.object(doctor, 'HOME', home), patch.object(doctor, 'CACHE', root/'cache'), \
                    patch.object(doctor, 'ROOT', root/'checkout'), \
                    patch.dict(os.environ, {'WORKSCRIBE_MIGRATE_LEGACY': '0'}), \
                    patch.object(sys, 'argv', ['doctor', '--remove-retired']), \
                    patch.object(doctor, 'install_nemo', side_effect=RuntimeError('offline')), \
                    patch.object(doctor, 'install', side_effect=RuntimeError('offline')), \
                    patch.object(doctor.subprocess, 'run', side_effect=RuntimeError('offline')), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertTrue(doctor.main())  # Active assets cannot be fetched here.
            self.assertFalse((home/'models/gemma-4-E4B-it-Q4_0.gguf').exists())
            self.assertFalse((home/'models/gemma-4-E4B-it-Q4_0.gguf.partial').exists())
            self.assertFalse((home/'models/vision').exists())
            self.assertIn('models/vision: removed', output.getvalue())
            # Nothing else is deleted: an older leftover stays, and so does a current model whose
            # replacement failed.
            self.assertEqual((home/'models/Qwen3.5-2B-Q4_K_M.gguf').read_bytes(), b'older model')
            self.assertEqual((home/'models/Nemotron-3-Diarization.q8_0.gguf').read_bytes(), b'speech model')
            self.assertEqual(set(json.loads((home/'checksums.json').read_text())), {'models/Nemotron-3-Diarization.q8_0.gguf'})
            self.assertFalse((root/'checkout').exists())

    def test_check_names_retired_files_without_deleting_or_requiring_them(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); home = self.retired_home(root)
            with patch.object(doctor, 'HOME', home), patch.object(doctor, 'CACHE', root/'cache'), \
                    patch.object(sys, 'argv', ['doctor', '--check']), \
                    patch.object(doctor, 'download', side_effect=AssertionError('network')), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertTrue(doctor.main())  # Active assets are intentionally absent.
            self.assertEqual((home/'models/gemma-4-E4B-it-Q4_0.gguf').read_bytes(), b'text model')
            self.assertEqual((home/'models/gemma-4-E4B-it-Q4_0.gguf.partial').read_bytes(), b'half a download')
            self.assertEqual((home/'models/vision/bin/image-caption').read_bytes(), b'helper')
            self.assertIn('models/vision: no longer used', output.getvalue())
            # Every mention says how to delete it; none reports it missing, wrong or needing attention.
            for line in output.getvalue().splitlines():
                if 'gemma-4-E4B' in line or 'models/vision' in line or 'image-caption' in line:
                    self.assertIn('no longer used', line)

    def test_retired_cleanup_stays_inside_the_runtime_home(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); outside = root/'outside'
            (outside/'vision/bin').mkdir(parents=True); (outside/'vision/bin/image-caption').write_bytes(b'elsewhere')
            (outside/'model.gguf').write_bytes(b'elsewhere')
            # Retired names that are links: the link goes, what it points at stays.
            linked = root/'linked'; (linked/'models').mkdir(parents=True)
            (linked/'models/vision').symlink_to(outside/'vision', target_is_directory=True)
            (linked/'models/gemma-4-E4B-it-Q4_0.gguf').symlink_to(outside/'model.gguf')
            with patch.object(doctor, 'HOME', linked), contextlib.redirect_stdout(io.StringIO()):
                doctor.remove_retired()
            self.assertFalse((linked/'models/vision').is_symlink())
            self.assertFalse((linked/'models/gemma-4-E4B-it-Q4_0.gguf').is_symlink())
            # A link inside the retired folder is not followed either.
            nested = root/'nested'; (nested/'models/vision').mkdir(parents=True)
            (nested/'models/vision/lib').symlink_to(outside/'vision', target_is_directory=True)
            with patch.object(doctor, 'HOME', nested), contextlib.redirect_stdout(io.StringIO()):
                doctor.remove_retired()
            self.assertFalse((nested/'models/vision').exists())
            # A models folder that lives elsewhere is not the runtime home: nothing in it is deleted.
            (outside/'models/vision').mkdir(parents=True); (outside/'models/vision/weights').write_bytes(b'elsewhere')
            (outside/'models/gemma-4-E4B-it-Q4_0.gguf').write_bytes(b'elsewhere')
            away = root/'away'; away.mkdir(); (away/'models').symlink_to(outside/'models', target_is_directory=True)
            with patch.object(doctor, 'HOME', away), contextlib.redirect_stdout(io.StringIO()) as output:
                doctor.remove_retired()
            self.assertIn('left in place', output.getvalue())
            for kept in ['vision/bin/image-caption', 'model.gguf', 'models/vision/weights', 'models/gemma-4-E4B-it-Q4_0.gguf']:
                self.assertEqual((outside/kept).read_bytes(), b'elsewhere', kept)

    def test_check_ignores_retired_receipts_without_removing_files(self):
        import json
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); home = root/'home'; cache = root/'cache'
            old = home/'models/qwen3-4b-instruct-2507-mlx/model.safetensors'
            old.parent.mkdir(parents=True); old.write_bytes(b'legacy bytes')
            receipt = home/'checksums.json'
            receipt.write_text(json.dumps({'models/qwen3-4b-instruct-2507-mlx/model.safetensors': 'stale hash'}))
            before = receipt.read_bytes()
            with patch.object(doctor, 'HOME', home), patch.object(doctor, 'CACHE', cache), \
                    patch.object(sys, 'argv', ['doctor', '--check']), \
                    patch.object(doctor, 'download', side_effect=AssertionError('network')), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertTrue(doctor.main())  # Active assets are intentionally absent.
            self.assertNotIn('qwen3', output.getvalue())
            self.assertEqual(old.read_bytes(), b'legacy bytes')
            self.assertEqual(receipt.read_bytes(), before)

    def test_product_migration_leaves_retired_files_in_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root/'old'; home = root/'home'
            (source/'models').mkdir(parents=True)
            active = 'Nemotron-3-Diarization.q8_0.gguf'
            (source/'models'/active).write_bytes(b'product fixture')
            for retired in ['Qwen3.5-2B-Q4_K_M.gguf', 'gemma-4-E4B-it-Q4_0.gguf']:
                (source/'models'/retired).write_bytes(b'old fixture')
            with patch.object(doctor, 'HOME', home):
                doctor.migrate(source, product_only=True)
            self.assertEqual((home/'models'/active).read_bytes(), b'product fixture')
            for retired in ['Qwen3.5-2B-Q4_K_M.gguf', 'gemma-4-E4B-it-Q4_0.gguf']:
                self.assertFalse((home/'models'/retired).exists())
                self.assertEqual((source/'models'/retired).read_bytes(), b'old fixture')

    def test_documented_downloads_match_installer_pins(self):
        import json
        root = Path(__file__).resolve().parents[2]
        rows = json.loads((root/'Resources/runtime-downloads.json').read_text())
        inventory = {item['path']: (item['sha256'], item['url']) for item in rows}
        for name, digest, url in doctor.specs():
            self.assertEqual(inventory[name], (digest, url))
        self.assertTrue(all(item['bytes'] > 0 for item in rows))

    def test_migration_preserves_source_and_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); source=root/'old'; source.mkdir()
            (source/'lib.1').write_bytes(b'abc'); (source/'lib').symlink_to('lib.1')
            with patch.object(doctor,'HOME',root/'new'):
                doctor.migrate(source)
                self.assertEqual((root/'new/lib').read_bytes(),b'abc')
                self.assertEqual((source/'lib.1').read_bytes(),b'abc')

    def test_materialize_requests_download_and_waits(self):
        with patch.object(doctor, 'state', side_effect=['evicted', 'evicted', 'present']), patch.object(doctor.subprocess, 'run') as run, patch.object(doctor.time, 'sleep'):
            doctor.materialize(Path('/fixture/model'))
        self.assertEqual(run.call_args.args[0], ['/usr/bin/brctl', 'download', '/fixture/model'])

    def test_native_reinstall_replaces_existing_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); home=root/'home'; cache=root/'cache'
            home.mkdir(); cache.mkdir(); source=root/'package'; (source/'lib').mkdir(parents=True)
            (source/'lib/real').write_bytes(b'new'); (source/'lib/link').symlink_to('real')
            archive=cache/'nemo-speech-0.2.0-macos-aarch64-metal.tar.gz'
            with tarfile.open(archive,'w:gz') as tar: tar.add(source,arcname='package')
            with patch.object(doctor,'HOME',home), patch.object(doctor,'CACHE',cache), patch.object(doctor,'download'):
                doctor.install_nemo()
                (home/'nemo/lib/real').write_bytes(b'corrupt')
                doctor.install_nemo()
            self.assertEqual((home/'nemo/lib/link').read_bytes(),b'new')
            self.assertFalse(list(home.glob('.nemo-previous-*')))

    def test_direct_doctor_does_not_mutate_packaged_scripts(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); scripts=root/'scripts'; scripts.mkdir()
            origin=Path(__file__).resolve().parents[1]
            for name in ['runtime-doctor.py', 'runtime_home.py', 'runtime_doctor_download.py']:
                shutil.copy2(origin/name, scripts/name)
            for name in ['fluidaudio/MODEL-SHA256.json', 'fluidaudio/MODEL-REVISION.txt', 'embeddinggemma2/MODEL-SHA256.json']:
                dest=root/'Resources/licenses'/name; dest.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(origin.parent/'Resources/licenses'/name,dest)
            env=dict(os.environ,HOME=str(root),WORKSCRIBE_RUNTIME_HOME=str(root/'home'))
            env.pop('PYTHONDONTWRITEBYTECODE',None)
            result=subprocess.run([sys.executable,str(scripts/'runtime-doctor.py'),'--check'],env=env,capture_output=True)
            self.assertEqual(result.returncode,1)
            self.assertFalse((scripts/'__pycache__').exists())

    def test_check_reports_missing_without_fetching(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(doctor,'HOME',Path(folder)/'home'), patch.object(doctor,'CACHE',Path(folder)/'cache'), patch.object(sys,'argv',['doctor','--check']), patch.object(doctor,'download',side_effect=AssertionError('download in check')), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertTrue(doctor.main())
            self.assertIn('missing',out.getvalue())
            self.assertIn('Models need attention',out.getvalue())
            # The retired text model and image helper are not requirements of a fresh setup.
            for retired in ['gemma-4-E4B', 'mmproj', 'models/vision', 'image-caption']:
                self.assertNotIn(retired, out.getvalue())

if __name__ == '__main__': unittest.main()
