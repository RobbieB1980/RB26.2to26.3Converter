import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

MODULE = Path(__file__).resolve().parents[1] / 'targets/rb-26.2-to-26.3/dependencies.py'
spec = importlib.util.spec_from_file_location('dependencies', MODULE)
dep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dep)


def jar(mod_id='example', dependencies=''):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as z:
        z.writestr('META-INF/neoforge.mods.toml', f'''modLoader="javafml"
loaderVersion="[1,)"
license="MIT"
[[mods]]
modId="{mod_id}"
version="1.0"
{dependencies}
''')
    return data.getvalue()


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def _metadata_fixture(self, source_text):
        source=self.root/'original.jar'
        data=io.BytesIO()
        with zipfile.ZipFile(data,'w') as z:
            z.writestr('META-INF/neoforge.mods.toml',source_text)
        source.write_bytes(data.getvalue())
        output=self.root/'out'
        target=output/'src/main/templates/META-INF/neoforge.mods.toml'
        target.parent.mkdir(parents=True)
        target.write_text('''modLoader="javafml"
loaderVersion="[4,)"
license="${mod_license}"

[[mods]]
modId="${mod_id}"
version="${mod_version}"
displayName="${mod_name}"
authors="${mod_authors}"
description=''' + "'''${mod_description}'''" + '''
''')
        return source,target

    def test_original_jar_required_optional_and_bundled(self):
        p = self.root / 'input.jar'
        p.write_bytes(jar(dependencies='''[[dependencies.example]]
modId='needed'
type='required'
versionRange='[2,)'
[[dependencies.example]]
modId='optional'
type='optional'
[[dependencies.example]]
modId='bad'
type='incompatible'
'''))
        with zipfile.ZipFile(p, 'a') as z:
            z.writestr('META-INF/jarjar/metadata.json', json.dumps({'jars':[{'identifier':{'group':'com.test','artifact':'embedded'},'path':'META-INF/jarjar/embedded.jar'}]}))
        records = {r['mod_id']:r for r in dep.detect(p, {})}
        self.assertEqual(records['needed']['kind'], 'required')
        self.assertEqual(records['optional']['kind'], 'optional')
        self.assertEqual(records['bad']['kind'], 'incompatible')
        self.assertEqual(records['embedded']['kind'], 'embedded')

    def test_no_wrong_game_loader_or_pin(self):
        versions = [dict(id='wrong',game_versions=['26.2'],loaders=['neoforge'],version_number='5.5.7'),dict(id='fabric',game_versions=['26.3'],loaders=['fabric'],version_number='5.5.7')]
        self.assertIsNone(dep.select_version(versions, '26.3', '5.5.7'))
        versions.append(dict(id='right',game_versions=['26.3'],loaders=['neoforge'],version_number='5.5.7',date_published='2026-09-01'))
        self.assertEqual(dep.select_version(versions,'26.3','5.5.7')['id'],'right')

    def test_hash_verification_cache_reuse_and_corruption(self):
        payload = jar()
        f = {'url':'https://cdn.modrinth.com/data/test/file.jar','filename':'test.jar','hashes':{'sha512':hashlib.sha512(payload).hexdigest()}}
        with patch.object(dep, 'download_bytes', return_value=payload) as fetch:
            p, status = dep.acquire(f, self.root / 'cache')
            self.assertEqual(status, 'downloaded')
            dep.acquire(f, self.root / 'cache')
            self.assertEqual(fetch.call_count, 1)
            p.write_bytes(b'corrupt')
            with self.assertRaises(ValueError):
                dep.acquire(f, self.root / 'cache', offline=True)
            dep.acquire(f, self.root / 'cache')
            self.assertEqual(fetch.call_count, 2)
        with patch.object(dep, 'download_bytes', return_value=b'bad'):
            with self.assertRaises(ValueError):
                dep.acquire(f, self.root / 'other')
        self.assertFalse(list((self.root / 'other').glob('*.jar')))

    def test_unknown_required_is_blocker_and_maven_is_preserved(self):
        source=self.root/'source'; source.mkdir()
        (source/'build.gradle').write_text("dependencies { implementation 'org.example:ordinary:1.0' }",encoding='utf8')
        meta=source/'src/main/resources/META-INF'; meta.mkdir(parents=True)
        (meta/'neoforge.mods.toml').write_text("[[dependencies.example]]\nmodId='unknown_required'\ntype='required'",encoding='utf8')
        records=dep.detect(source,{})
        self.assertTrue(any(r['kind']=='maven' for r in records))
        report=dep.resolve(records,self.root/'cache',{},offline=True)
        self.assertTrue(any(r['status']=='blocked' and r['mod_id']=='unknown_required' for r in report))

    def test_traversal_filename_rejected(self):
        with self.assertRaises(ValueError):
            dep.acquire({'filename':'../escape.jar','url':'https://cdn.modrinth.com/x','hashes':{'sha512':'a'*128}},self.root)

    def test_resource_audit_restores_missing_and_reports_changes(self):
        source=self.root/'original.jar'
        source.write_bytes(jar())
        with zipfile.ZipFile(source,'a') as z:
            z.writestr('assets/example/models/test.json','{"original":true}')
            z.writestr('data/example/loot_table/test.json','{}')
        output=self.root/'out'
        changed=output/'src/main/resources/data/example/loot_table/test.json'
        changed.parent.mkdir(parents=True)
        changed.write_text('{"changed":true}')
        report=dep.audit_resources(source,output)
        self.assertEqual(len(report['restored_missing']),2)  # model and mod metadata
        self.assertEqual(len(report['changed']),1)
        self.assertTrue((output/'src/main/resources/assets/example/models/test.json').exists())
        self.assertEqual(changed.read_text(),'{"changed":true}')
        self.assertTrue((output/'.gokuai/source-evidence/input.jar').exists())

    def test_generated_metadata_not_restored_as_duplicate(self):
        source=self.root/'original.jar';source.write_bytes(jar())
        output=self.root/'out'
        target=output/'src/main/templates/META-INF/neoforge.mods.toml'
        target.parent.mkdir(parents=True);target.write_text('[[mods]]\nmodId="example"\nversion="1.0-26.3"')
        dep.audit_resources(source,output)
        self.assertFalse((output/'src/main/resources/META-INF/neoforge.mods.toml').exists())

    def test_metadata_preservation_keeps_source_fields_and_target_pins(self):
        source=self.root/'original.jar'
        original='''modLoader="javafml"
loaderVersion="[4,)"
license="Custom License"
issueTrackerURL="https://example.invalid/issues"

[[mods]]
modId="fixture"
version="2.7.1"
displayName="Source Fixture"
displayURL="https://example.invalid/home"
iconFile="assets/fixture/icon.png"
authors="Source Author"
description=''' + "'''Preserve this source description'''" + '''
customField="keep-this-field"

[[mixins]]
config="fixture.mixins.json"

[[accessTransformers]]
file="META-INF/fixture.cfg"

[[dependencies.fixture]]
modId="configuration"
type="required"
versionRange="[4,5)"
ordering="AFTER"
side="BOTH"
'''
        data=io.BytesIO()
        with zipfile.ZipFile(data,'w') as z:
            z.writestr('META-INF/neoforge.mods.toml',original)
        source.write_bytes(data.getvalue())
        output=self.root/'out'
        target=output/'src/main/templates/META-INF/neoforge.mods.toml'
        target.parent.mkdir(parents=True)
        target.write_text('''modLoader="javafml"
loaderVersion="[4,)"
license="${mod_license}"

[[mods]]
modId="${mod_id}"
version="${mod_version}"
displayName="${mod_name}"
authors="${mod_authors}"
description=''' + "'''${mod_description}'''" + '''

# Generated equivalent registration with different comments.
[[mixins]]
config="fixture.mixins.json"

# Generated equivalent access transformer registration.
[[accessTransformers]]
file="META-INF/fixture.cfg"

[[dependencies.${mod_id}]]
modId="neoforge"
type="required"
versionRange="[${neo_version},)"
ordering="NONE"
side="BOTH"
''')
        dep.preserve_dependency_metadata(source,output)
        result=target.read_text()
        self.assertIn('license="Custom License"',result)
        self.assertIn('issueTrackerURL="https://example.invalid/issues"',result)
        self.assertIn('displayName="Source Fixture"',result)
        self.assertIn('displayURL="https://example.invalid/home"',result)
        self.assertIn('iconFile="assets/fixture/icon.png"',result)
        self.assertIn('authors="Source Author"',result)
        self.assertIn("description='''Preserve this source description'''",result)
        self.assertIn('customField="keep-this-field"',result)
        self.assertIn('[[mixins]]',result)
        self.assertIn('config="fixture.mixins.json"',result)
        self.assertIn('[[accessTransformers]]',result)
        self.assertIn('file="META-INF/fixture.cfg"',result)
        self.assertEqual(result.count('[[mixins]]'),1)
        self.assertEqual(result.count('[[accessTransformers]]'),1)
        self.assertIn('modId="${mod_id}"',result)
        self.assertIn('version="${mod_version}"',result)
        self.assertIn('versionRange="[${neo_version},)"',result)
        self.assertEqual(result.count('[[dependencies.fixture]]'),1)
        dep.preserve_dependency_metadata(source,output)
        self.assertEqual(result,target.read_text())

    def test_metadata_guard_rejects_multiline_array_without_writing(self):
        source,target=self._metadata_fixture('''modLoader="javafml"
loaderVersion="[4,)"
license="MIT"
[[mods]]
modId="fixture"
version="1.0"
customList=["first",
"second"]
''')
        before=target.read_bytes()
        with self.assertRaisesRegex(ValueError,'multiline array'):
            dep.preserve_dependency_metadata(source,target.parents[4])
        self.assertEqual(before,target.read_bytes())

    def test_metadata_guard_rejects_standard_table_before_mods_without_writing(self):
        source,target=self._metadata_fixture('''modLoader="javafml"
loaderVersion="[4,)"
license="MIT"
[custom]
enabled=true
[[mods]]
modId="fixture"
version="1.0"
''')
        before=target.read_bytes()
        with self.assertRaisesRegex(ValueError,'standard TOML tables'):
            dep.preserve_dependency_metadata(source,target.parents[4])
        self.assertEqual(before,target.read_bytes())

    def test_metadata_guard_rejects_standard_table_after_mods_without_writing(self):
        source,target=self._metadata_fixture('''modLoader="javafml"
loaderVersion="[4,)"
license="MIT"
[[mods]]
modId="fixture"
version="1.0"
[custom]
enabled=true
''')
        before=target.read_bytes()
        with self.assertRaisesRegex(ValueError,'standard TOML tables'):
            dep.preserve_dependency_metadata(source,target.parents[4])
        self.assertEqual(before,target.read_bytes())

    def test_metadata_guard_rejects_multiple_mods_without_writing(self):
        source,target=self._metadata_fixture('''modLoader="javafml"
loaderVersion="[4,)"
license="MIT"
[[mods]]
modId="fixture"
version="1.0"
[[mods]]
modId="second"
version="1.0"
''')
        before=target.read_bytes()
        with self.assertRaisesRegex(ValueError,r'exactly one \[\[mods\]\]'):
            dep.preserve_dependency_metadata(source,target.parents[4])
        self.assertEqual(before,target.read_bytes())

    def test_version_range_guard(self):
        self.assertTrue(dep.version_allowed('5.5.7','[5.5,)'))
        self.assertFalse(dep.version_allowed('5.5.7','[4,5)'))
        self.assertTrue(dep.version_allowed('5.5.7','[5.5.7]'))
        self.assertTrue(dep.version_allowed('4.1.4+26.3','[4,5)'))
        self.assertFalse(dep.version_allowed('5.0+26.3','[4,5)'))
        with self.assertRaises(ValueError):
            dep.version_allowed('4.1.4-beta+26.3','[4,5)')
        with self.assertRaises(ValueError):
            dep.version_allowed('4.1.4+26.2','[4,5)')

    def test_api_findings_do_not_edit_sources(self):
        path=self.root/'src/main/java/Example.java';path.parent.mkdir(parents=True)
        text='class Example extends AxeItem {\nvoid draw() { stack.mulPose(q); }\n}'
        path.write_text(text)
        report=dep.scan_api(self.root)
        self.assertEqual(len(report['findings']),2)
        self.assertEqual(path.read_text(),text)

    def test_transitive_requirement_cannot_disappear(self):
        payload=jar('example')
        version=dict(id='ABC123',project_id='PRJ123',version_number='1.0',game_versions=['26.3'],loaders=['neoforge'],
            files=[dict(primary=True,filename='example.jar',url='https://cdn.modrinth.com/example.jar',hashes={'sha512':hashlib.sha512(payload).hexdigest()})],
            dependencies=[dict(dependency_type='required',project_id=None,version_id=None)])
        def reply(path):
            return [] if '26.2' in path else [version]
        with patch.object(dep,'api',side_effect=reply),patch.object(dep,'download_bytes',return_value=payload):
            results=dep.resolve([dict(mod_id='example',kind='required',version_range='',origin='test')],self.root/'cache',{'example':{'modrinth':'example'}})
        self.assertTrue(any(r['status']=='blocked' and r['mod_id']=='external-required-example' for r in results))

    def test_gradle_wiring_is_idempotent_and_keeps_other_maven_dependencies(self):
        project=self.root/'out';project.mkdir()
        original='dependencies { implementation "com.geckolib:geckolib-neoforge-26.2:5.5.3"; api "org.other:keep:1.0" }\n'
        build=project/'build.gradle';build.write_text(original)
        cached=self.root/'cached.jar';cached.write_bytes(jar('geckolib'))
        records=[dict(mod_id='geckolib',coordinate='com.geckolib:geckolib-neoforge-26.2:5.5.3')]
        results=[dict(mod_id='geckolib',status='cached',project_id='PRJ123',version_id='VER123',jar=str(cached))]
        dep.wire(project,records,results)
        first=build.read_text()
        dep.wire(project,records,results)
        self.assertEqual(first,build.read_text())
        self.assertIn('org.other:keep:1.0',first)
        self.assertNotIn('neoforge-26.2',first)
        self.assertEqual(first.count('libs/rb-26.3/PRJ123-VER123.jar'),1)

    def test_legacy_target_is_rejected_without_writing(self):
        project=self.root/'legacy';project.mkdir()
        manifest=project/'conversion-manifest.json'
        manifest.write_text(json.dumps({'target_id':'legacy','target_minecraft':'26.2'}))
        before=list(project.iterdir())
        with self.assertRaises(ValueError):
            dep.run(self.root/'source.jar',project,self.root/'cache')
        self.assertEqual(before,list(project.iterdir()))


if __name__ == '__main__':
    unittest.main()
