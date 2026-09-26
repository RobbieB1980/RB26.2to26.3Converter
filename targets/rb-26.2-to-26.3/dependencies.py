"""Exact-target dependency acquisition. Python 3.14, standard library only.

Metadata is evidence, never executable instructions. Unknown/dynamic Gradle
expressions and bundled libraries require review; no speculative dependency ports.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
import tomllib
from urllib.parse import urlencode, urlparse, quote
from urllib.request import Request, urlopen
import uuid
import zipfile

PLATFORM = {'minecraft', 'neoforge', 'forge', 'java', 'fml'}
UA = 'RB262To263Converter/1.0 (https://github.com/RobbieB1980/RB26.2to26.3Converter)'
API = 'https://api.modrinth.com/v2'


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    os.replace(temp, path)


def download_bytes(url):
    if urlparse(url).scheme != 'https':
        raise ValueError('Downloads require HTTPS')
    with urlopen(Request(url, headers={'User-Agent': UA}), timeout=45) as response:
        if urlparse(response.url).scheme != 'https':
            raise ValueError('Insecure redirect rejected')
        return response.read()


def api(path):
    return json.loads(download_bytes(API + path))


def metadata(text):
    # ModDevGradle templates commonly use an unquoted ${mod_id} table key.
    text = re.sub(r'(\[\[dependencies\.)\$\{mod_id\}(\]\])', r'\1"${mod_id}"\2', text)
    return tomllib.loads(text.lstrip('\ufeff'))


def detect(source, catalog):
    source = Path(source)
    records = []
    def read_meta(text, origin):
        data = metadata(text)
        for blocks in data.get('dependencies', {}).values():
            for d in blocks:
                mid = d.get('modId', '')
                if mid and mid not in PLATFORM:
                    records.append(dict(mod_id=mid, kind=d.get('type', 'required' if d.get('mandatory', True) else 'optional'), version_range=d.get('versionRange',''), side=d.get('side','BOTH'), origin=origin))
    def read_embedded(text, origin):
        for d in json.loads(text).get('jars', []):
            records.append(dict(mod_id=d.get('identifier',{}).get('artifact','unknown-embedded'), kind='embedded', version_range='', origin=origin, embedded_path=d.get('path','')))
    if source.is_file():
        with zipfile.ZipFile(source) as z:
            for name in ('META-INF/neoforge.mods.toml', 'META-INF/mods.toml'):
                if name in z.namelist():
                    read_meta(z.read(name).decode('utf-8-sig'), name)
            if 'META-INF/jarjar/metadata.json' in z.namelist():
                read_embedded(z.read('META-INF/jarjar/metadata.json').decode('utf-8-sig'), 'jarjar')
    else:
        for name in ('src/main/resources/META-INF/neoforge.mods.toml', 'src/main/resources/META-INF/mods.toml', 'src/main/templates/META-INF/neoforge.mods.toml'):
            p=source/name
            if p.exists():
                read_meta(p.read_text(encoding='utf-8-sig'),name)
        p=source/'src/main/resources/META-INF/jarjar/metadata.json'
        if p.exists():
            read_embedded(p.read_text(encoding='utf-8-sig'),str(p.relative_to(source)))
        for name in ('build.gradle','build.gradle.kts'):
            p=source/name
            if not p.exists():
                continue
            text=p.read_text(encoding='utf-8-sig')
            # Literal dependencies only: dynamic/version-catalog declarations stay
            # in the original build and are explicitly reported for Gradle review.
            pattern=r'(?m)^\s*(implementation|api|compileOnly|runtimeOnly|modImplementation|modCompileOnly|modRuntimeOnly)\s*\(?\s*[\'"]([^\'"\r\n]+)[\'"]'
            # Also support compact one-line dependencies blocks.
            pattern=pattern.replace('(?m)^\\s*', r'\b')
            matches=list(re.finditer(pattern,text))
            for match in matches:
                coord=match[2]
                if ':' not in coord:
                    continue
                artifact=coord.split(':')[1]
                identity=next((key for key,e in catalog.items() if any(artifact.lower()==a.lower() or ('-neoforge-' in a and artifact.lower().startswith(a.lower().split('-neoforge-')[0]+'-neoforge-')) for a in e.get('artifacts',[]))),None)
                records.append(dict(mod_id=identity or artifact,kind='required' if identity or '26.2' in coord else 'maven',version_range='',origin=name,coordinate=coord,configuration=match[1]))
            if re.search(r'\b(?:implementation|api|compileOnly|runtimeOnly)\s*\(?\s*(?:libs\.|files\(|fileTree\(|project\(|fg\.)',text):
                records.append(dict(mod_id='gradle-dynamic',kind='review',version_range='',origin=name))
        # Package imports are exact prefixes from the trusted identity catalog.
        java=source/'src/main/java'
        if java.exists():
            for f in java.rglob('*.java'):
                text=f.read_text(encoding='utf-8-sig',errors='replace')
                for mid,e in catalog.items():
                    if any(re.search(r'(?m)^\s*import\s+(?:static\s+)?'+re.escape(prefix)+r'\.', text) for prefix in e.get('imports',[])):
                        records.append(dict(mod_id=mid,kind='required',version_range='',origin=str(f.relative_to(source))))
    # Preserve all declarations for diagnosis; resolution later deduplicates by ID.
    return records


def select_version(versions, game, pin=None):
    valid=[v for v in versions if game in v.get('game_versions',[]) and 'neoforge' in v.get('loaders',[]) and (not pin or v.get('version_number')==pin) and v.get('status','listed') in ('listed','archived')]
    return next(iter(sorted(valid,key=lambda v:(v.get('version_type')=='release',v.get('date_published','')),reverse=True)),None)


def version_allowed(version, constraint):
    if not constraint or constraint=='*':
        return True
    def number(v):
        if not re.fullmatch(r'\d+(?:\.\d+)*',v):
            raise ValueError('Dependency range needs manual review: '+constraint)
        parts=tuple(map(int,v.split('.')))
        return parts+(0,)*(8-len(parts))
    actual=number(version)
    exact=re.fullmatch(r'\[([^,]+)\]',constraint)
    if exact:
        return actual==number(exact[1])
    bounds=re.fullmatch(r'([\[(])([^,]*),([^\])]*)([\])])',constraint)
    if not bounds:
        raise ValueError('Dependency range needs manual review: '+constraint)
    lower,upper=bounds[2].strip(),bounds[3].strip()
    return (not lower or actual>number(lower) or (bounds[1]=='[' and actual==number(lower))) and (not upper or actual<number(upper) or (bounds[4]==']' and actual==number(upper)))


def acquire(file, directory, offline=False):
    name=file['filename']
    if not re.fullmatch(r'[A-Za-z0-9_.+\-]+\.jar',name) or name.startswith('.'):
        raise ValueError('Unsafe dependency filename')
    if urlparse(file['url']).hostname != 'cdn.modrinth.com':
        raise ValueError('Artifact is not on the verified Modrinth CDN')
    hashes=file.get('hashes',{})
    algorithm=next((a for a in ('sha512','sha256') if hashes.get(a)),None)
    if not algorithm or not re.fullmatch('[a-fA-F0-9]{'+str(hashlib.new(algorithm).digest_size*2)+'}',hashes[algorithm]):
        raise ValueError('No valid upstream SHA-512/SHA-256 checksum')
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=True)
    destination=directory/name
    def verified(data):
        return hashlib.new(algorithm,data).hexdigest().lower()==hashes[algorithm].lower()
    if destination.exists() and verified(destination.read_bytes()):
        return destination,'cached'
    if offline:
        raise ValueError('Offline cache is missing or its checksum failed')
    data=download_bytes(file['url'])
    if not verified(data):
        raise ValueError('Downloaded dependency checksum mismatch')
    import io
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        if z.testzip():
            raise ValueError('Invalid dependency JAR')
    temp=destination.with_name(name+'.'+uuid.uuid4().hex+'.part')
    temp.write_bytes(data);os.replace(temp,destination)
    return destination,'downloaded'


def resolve(records, cache, catalog, offline=False, gecko_pin='5.5.7'):
    cache=Path(cache)
    for game in ('26.2','26.3'):
        (cache/('minecraft-'+game)).mkdir(parents=True,exist_ok=True)
    results=[];queue=list(records);seen=set();selections={}
    while queue:
        r=dict(queue.pop(0));mid=r['mod_id'];kind=r['kind']
        if mid in seen:
            if r.get('version_id') and selections.get(r.get('project_id')) not in (None,r['version_id']):
                results.append(dict(r,status='blocked',reason='Conflicting exact transitive dependency versions'))
            continue
        # A required declaration wins over optional duplicates.
        if any(x['mod_id']==mid and x['kind']=='required' for x in records):
            kind=r['kind']='required'
        seen.add(mid)
        if len(seen)>128:
            results.append(dict(r,status='blocked',reason='Dependency graph exceeded 128 nodes'));break
        if kind in ('optional','incompatible','discouraged','embedded','review','maven'):
            r.update(status='review' if kind in ('embedded','review') else 'preserved',reason='Retained for review; no automatic replacement' if kind in ('embedded','review') else 'Optional/incompatible declaration or existing Maven dependency preserved')
            results.append(r);continue
        entry=catalog.get(mid,{}) or next((e for e in catalog.values() if mid in e.get('aliases',[])),{})
        project=r.get('project_id') or entry.get('modrinth')
        if not project:
            results.append(dict(r,status='blocked',reason='No verified project identity in dependency-index.json; refusing name-search guesses'));continue
        try:
            if not re.fullmatch(r'[A-Za-z0-9_-]+',project):
                raise ValueError('Invalid project identity')
            version_dir=cache/'minecraft-26.3'/project
            saved=[]
            for p in version_dir.glob('*/version.json'):
                saved.append(json.loads(p.read_text(encoding='utf-8-sig')))
            pin=gecko_pin if mid=='geckolib' else None
            exact=r.get('version_id')
            if offline:
                versions=[v for v in saved if not exact or v['id']==exact]
            elif exact:
                versions=[api('/version/'+quote(exact,safe=''))]
            else:
                versions=api('/project/'+quote(project,safe='')+'/version?'+urlencode({'loaders':json.dumps(['neoforge']),'game_versions':json.dumps(['26.3']),'include_changelog':'false'}))
            v=select_version(versions,'26.3',pin)
            if not v:
                raise ValueError('No verified NeoForge 26.3 release matches the requested pin')
            constraints=[d.get('version_range','') for d in records if d['mod_id']==mid] or [r.get('version_range','')]
            if any(not version_allowed(v['version_number'],c) for c in constraints):
                raise ValueError('Target version violates an original declared dependency range; explicit migration review required')
            if r.get('project_id') and v['project_id']!=r['project_id']:
                raise ValueError('Transitive project identity mismatch')
            previous=selections.get(v['project_id'])
            if previous and previous!=v['id']:
                raise ValueError('Conflicting exact dependency version requirements')
            selections[v['project_id']]=v['id']
            files=[f for f in v['files'] if f.get('primary') and f['filename'].endswith('.jar')]
            if len(files)!=1:
                raise ValueError('Release has no unambiguous primary JAR')
            if not re.fullmatch(r'[A-Za-z0-9]+',v['id']):
                raise ValueError('Invalid version identifier')
            dest=version_dir/v['id']
            path,state=acquire(files[0],dest,offline)
            with zipfile.ZipFile(path) as z:
                name='META-INF/neoforge.mods.toml'
                if name not in z.namelist():
                    raise ValueError('Target JAR lacks NeoForge metadata')
                data=metadata(z.read(name).decode('utf-8-sig'))
                ids=[m.get('modId') for m in data.get('mods',[])]
                if not r.get('project_id') and mid not in ids and not any(a in ids for a in entry.get('aliases',[])):
                    raise ValueError('Downloaded JAR mod ID does not match dependency')
                for blocks in data.get('dependencies',{}).values():
                    for declared in blocks:
                        required=declared.get('type','required' if declared.get('mandatory',True) else 'optional')=='required'
                        child=declared.get('modId')
                        if child=='minecraft' and not version_allowed('26.3',declared.get('versionRange','')):
                            raise ValueError('JAR Minecraft dependency range does not accept 26.3')
                        if required and child and child not in PLATFORM and child not in ids:
                            queue.append(dict(mod_id=child,kind='required',origin=mid,version_range=declared.get('versionRange','')))
            write_json(dest/'version.json',v)
            r.update(status=state,project_id=v['project_id'],version_id=v['id'],version=v['version_number'],jar=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),url=files[0]['url'],upstream_hashes=files[0]['hashes'],game_version='26.3',loader='neoforge',mod_ids=ids,license_source='https://modrinth.com/project/'+project)
            # Required transitive dependencies are never silently ignored.
            for d in v.get('dependencies',[]):
                if d['dependency_type']=='required':
                    pid=d.get('project_id')
                    if not pid and d.get('version_id') and not offline:
                        pid=api('/version/'+quote(d['version_id'],safe=''))['project_id']
                    if pid:
                        queue.append(dict(mod_id='modrinth-'+pid,kind='required',origin=mid,project_id=pid,version_id=d.get('version_id'),version_range=''))
                    else:
                        results.append(dict(mod_id='external-required-'+mid,kind='required',status='blocked',reason='Required transitive dependency has no resolvable project identity'))
            # Cache the source release only as evidence; never place it on target classpath.
            if not offline and not r.get('origin','').startswith('modrinth-'):
                try:
                    sv=select_version(api('/project/'+quote(project,safe='')+'/version?'+urlencode({'loaders':'["neoforge"]','game_versions':'["26.2"]','include_changelog':'false'})),'26.2')
                    sf=next((f for f in sv['files'] if f.get('primary') and f['filename'].endswith('.jar')),None) if sv else None
                    if sf:
                        sp,_=acquire(sf,cache/'minecraft-26.2'/project/sv['id'])
                        write_json(sp.parent/'version.json',sv)
                        r['source_reference_jar']=str(sp)
                        r['source_reference_note']='Compatible 26.2 reference release; not proof of original dependency version'
                except Exception as e:
                    r['source_reference_warning']=str(e)
        except Exception as e:
            r.update(status='blocked',reason=str(e))
        results.append(r)
    return results


def wire(project, records, results):
    """Append an isolated Gradle script; replace only catalog-matched literals.

    No arbitrary Gradle AST is guessed. Dynamic structures are left for repair.
    """
    project=Path(project)
    build=next((project/n for n in ('build.gradle','build.gradle.kts') if (project/n).exists()),None)
    if not build:
        raise ValueError('Output has no Gradle build file')
    text=build.read_text(encoding='utf-8-sig')
    generated=['// Generated RB 26.3 dependency cache. Do not put source 26.2 JARs here.', 'dependencies {']
    for r in results:
        if r['status'] not in ('downloaded','cached'):
            continue
        filename=r['project_id']+'-'+r['version_id']+'.jar'
        target=project/'libs/rb-26.3'/filename
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(r['jar'],target)
        coords={d['coordinate'] for d in records if d['mod_id']==r['mod_id'] and d.get('coordinate')}
        replaced=False
        text,n=re.subn(r'libs/rb-26\.3/'+re.escape(r['project_id'])+r'-[A-Za-z0-9]+\.jar','libs/rb-26.3/'+filename,text)
        replaced=bool(n)
        for coord in coords:
            # Replace entire literal dependency invocation, preserving configuration.
            pattern=r'\b(implementation|api|compileOnly|runtimeOnly|modImplementation|modCompileOnly|modRuntimeOnly)\s*(\()?\s*([\'\"])'+re.escape(coord)+r'\3\s*(?(2)\))'
            replacement=lambda m:m[1]+'(files("libs/rb-26.3/'+filename+'"))'
            text,n=re.subn(pattern,replacement,text)
            replaced=replaced or n>0
        if not replaced:
            generated.append('    implementation files("libs/rb-26.3/'+filename+'")')
    generated.append('}')
    (project/'rb-dependencies.gradle').write_text('\n'.join(generated)+'\n',encoding='utf-8')
    apply='apply(from = "rb-dependencies.gradle")' if build.suffix=='.kts' else 'apply from: "rb-dependencies.gradle"'
    if apply not in text:
        text+='\n'+apply+'\n'
    build.write_text(text,encoding='utf-8')


def preserve_dependency_metadata(source, project):
    """Keep original non-platform dependency declarations through JAR scaffolding."""
    if not Path(source).is_file():
        return
    with zipfile.ZipFile(source) as z:
        name=next((n for n in ('META-INF/neoforge.mods.toml','META-INF/mods.toml') if n in z.namelist()),None)
        if not name:
            return
        original=z.read(name).decode('utf-8-sig')
    target=Path(project)/'src/main/templates/META-INF/neoforge.mods.toml'
    if not target.exists():
        target=Path(project)/'src/main/resources/META-INF/neoforge.mods.toml'
    if not target.exists():
        return
    text=target.read_text(encoding='utf-8-sig')
    pattern=r'(?ms)^\[\[dependencies\.[^\r\n]+\]\].*?(?=^\[|\Z)'
    def modid(block):
        parsed=metadata(block)
        return next(iter(parsed['dependencies'].values()))[0].get('modId')
    original_blocks=[b[0] for b in re.finditer(pattern,original) if modid(b[0]) not in PLATFORM]
    ids={modid(b) for b in original_blocks}
    text=re.sub(pattern,lambda m:'' if modid(m[0]) in ids else m[0],text)
    target.write_text(text.rstrip()+'\n\n'+'\n'.join(original_blocks)+'\n',encoding='utf-8')


def scan_api(project, rules=None):
    project=Path(project)
    rules=rules or json.loads((Path(__file__).parent/'knowledge/api-review-rules.json').read_text(encoding='utf-8-sig'))
    findings=[]
    for path in (project/'src/main/java').rglob('*.java'):
        lines=path.read_text(encoding='utf-8-sig',errors='replace').splitlines()
        for rule in rules['rules']:
            for number,line in enumerate(lines,1):
                if any(re.search(pattern,line) for pattern in rule['patterns']):
                    findings.append({'rule':rule['id'],'file':str(path.relative_to(project)),'line':number,'excerpt':line.strip()[:300],'action':rule['action'],'evidence':rule['evidence'],'status':'needs-exact-source-review'})
    report={'source':'26.2','target':'26.3','findings':findings,'automatic_edits':False}
    write_json(project/'API_REVIEW-26.3.json',report)
    print(f'API review: {len(findings)} exact-source review locations',flush=True)
    return report


def audit_resources(source, project):
    source=Path(source);project=Path(project)
    resource_root=project/'src/main/resources'
    original=project/'.gokuai/source-evidence'
    original.mkdir(parents=True,exist_ok=True)
    report={'unchanged':[], 'changed':[], 'restored_missing':[], 'excluded_archive_metadata':[], 'runtime':'not-tested'}
    def check(name, data):
        name=name.replace('\\','/')
        dest=(resource_root/name).resolve()
        if not dest.is_relative_to(resource_root.resolve()):
            raise ValueError('Unsafe resource path in input: '+name)
        if name.endswith('.class'):
            return
        if name.upper()=='META-INF/MANIFEST.MF' or re.match(r'(?i)^META-INF/[^/]+\.(SF|RSA|DSA|EC)$',name):
            report['excluded_archive_metadata'].append(name);return
        if name=='META-INF/mods.toml' and (resource_root/'META-INF/neoforge.mods.toml').exists():
            report['changed'].append({'path':name,'reason':'Replaced by NeoForge metadata; original retained'});return
        entry={'path':name,'source_sha256':hashlib.sha256(data).hexdigest()}
        template=project/'src/main/templates'/name
        if name=='META-INF/neoforge.mods.toml' and template.exists():
            entry.update(output_sha256=hashlib.sha256(template.read_bytes()).hexdigest(),reason='Generated from src/main/templates; original retained as evidence')
            report['changed'].append(entry)
            return
        if not dest.exists():
            dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
            report['restored_missing'].append(entry)
        else:
            entry['output_sha256']=hashlib.sha256(dest.read_bytes()).hexdigest()
            report['unchanged' if entry['source_sha256']==entry['output_sha256'] else 'changed'].append(entry)
    if source.is_file():
        shutil.copyfile(source,original/'input.jar')
        with zipfile.ZipFile(source) as z:
            for info in z.infolist():
                if not info.is_dir():
                    check(info.filename,z.read(info))
    else:
        source_resources=source/'src/main/resources'
        if source_resources.exists():
            for p in source_resources.rglob('*'):
                if p.is_file():
                    name=p.relative_to(source_resources).as_posix()
                    saved=original/'resources'/name
                    saved.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,saved)
                    check(name,p.read_bytes())
    write_json(project/'RESOURCE_PRESERVATION.json',report)
    print(f"Resource audit: {len(report['unchanged'])} unchanged, {len(report['changed'])} changed, {len(report['restored_missing'])} restored; originals retained",flush=True)
    return report


def run(source, project, cache, offline=False, gecko_pin='5.5.7'):
    source=Path(source).resolve();project=Path(project).resolve();cache=Path(cache).resolve()
    manifest=project/'conversion-manifest.json'
    if manifest.exists():
        m=json.loads(manifest.read_text(encoding='utf-8-sig'))
        if m.get('target_id')!='rb-26.2-to-26.3' or m.get('target_minecraft')!='26.3':
            raise ValueError('Refusing to change a project outside the 26.2 to 26.3 target')
    write_json(project/'dependency-resolution.json',{'source_minecraft':'26.2','target_minecraft':'26.3','blocked_required':1,'records':[], 'status':'resolution-in-progress','runtime':'not-tested'})
    bundled=json.loads((Path(__file__).parent/'knowledge/dependency-index.json').read_text(encoding='utf-8-sig'))
    index_path=cache/'dependency-index.json'
    cache.mkdir(parents=True,exist_ok=True)
    # One short-lived OS file lock serializes index updates and resolver runs.
    import msvcrt
    with (cache/'index.lock').open('a+b') as lock:
        lock.seek(0);lock.write(b'0');lock.flush();lock.seek(0)
        msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
        try:
            index=json.loads(index_path.read_text(encoding='utf-8-sig')) if index_path.exists() else bundled
            if index.get('target_minecraft')!='26.3' or index.get('schema_version')!=1:
                raise ValueError('Dependency index schema or target mismatch')
            catalog=index['projects']
            preserve_dependency_metadata(source,project)
            audit_resources(source,project)
            scan_api(project)
            records=detect(source,catalog)
            # Source import detection survives JAR decompilation, without trusting
            # the intermediate scaffold's old 26.2 dependency resolutions.
            if source.is_file():
                records += [r for r in detect(project,catalog) if r['origin'].endswith('.java') or r.get('coordinate')]
            write_json(project/'dependency-detection.json',{'source':str(source),'records':records})
            results=resolve(records,cache,catalog,offline,gecko_pin)
            wire(project,records,results)
            blockers=[r for r in results if r['status']=='blocked']
            report={'source_minecraft':'26.2','target_minecraft':'26.3','cache':str(cache),'records':results,'blocked_required':len(blockers),'runtime':'not-tested'}
            write_json(project/'dependency-resolution.json',report)
            rows=['# 26.2 -> 26.3 dependency report','', 'Required blockers: '+str(len(blockers)), 'Runtime validation: not tested','']
            for r in results:
                rows.append('- '+r['mod_id']+': '+r['status']+' ('+r['kind']+') '+r.get('version',r.get('reason','')))
                print('Dependency '+r['mod_id']+': '+r['status']+' '+r.get('reason',r.get('version','')),flush=True)
            (project/'DEPENDENCIES-26.3.md').write_text('\n'.join(rows)+'\n',encoding='utf-8')
            known={r['sha256']:r for r in index.get('artifacts',[])}
            for r in results:
                if r['status'] in ('downloaded','cached'):
                    known[r['sha256']]=r
            index['artifacts']=list(known.values());write_json(index_path,index)
            print('Dependency report: '+str(project/'DEPENDENCIES-26.3.md'),flush=True)
            return len(blockers)
        except Exception as error:
            write_json(project/'dependency-resolution.json',{'source_minecraft':'26.2','target_minecraft':'26.3','blocked_required':1,'records':[], 'status':'failed','reason':str(error),'runtime':'not-tested'})
            raise
        finally:
            lock.seek(0);msvcrt.locking(lock.fileno(),msvcrt.LK_UNLCK,1)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',required=True);parser.add_argument('--project',required=True)
    parser.add_argument('--cache',default=r'C:\GokuCodexAI\Data\Mod_Dependencies')
    parser.add_argument('--gecko',default='5.5.7');parser.add_argument('--offline',action='store_true')
    args=parser.parse_args()
    try:
        pin=args.gecko.removeprefix('geckolib-neoforge-26.3-')
        sys.exit(3 if run(args.source,args.project,args.cache,args.offline,pin) else 0)
    except Exception as error:
        print('Dependency resolution failed: '+str(error),file=sys.stderr)
        sys.exit(2)
