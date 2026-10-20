import Foundation

/// Shared installation program, invoked only by the explicit integration flow.
/// Python is an installation dependency, not a transcript ingestion dependency.
public enum AgentHostDeployment {
    public static let maximumArtifactBytes = 16 * 1024 * 1024
    public static let chunkBytes = 32 * 1024

    public struct Request: Codable, Sendable {
        public let operation: String
        public let upload: String?
        public let sha256: String?
        public let bytes: Int?
        public let offset: Int?
        public let content: String?
        public let expectedCurrent: String?
        /// Stamped by `command(_:)` from this build, never by a platform, so
        /// activation can refuse to replace a newer integration's host.
        public let integration: Int?
        public init(operation: String, upload: String? = nil, sha256: String? = nil,
                    bytes: Int? = nil, offset: Int? = nil, content: String? = nil, expectedCurrent: String? = nil,
                    integration: Int? = nil) {
            self.operation = operation; self.upload = upload; self.sha256 = sha256
            self.bytes = bytes; self.offset = offset; self.content = content
            self.expectedCurrent = expectedCurrent; self.integration = integration
        }
    }

    public static func command(_ request: Request) throws -> String {
        guard ["probe", "begin", "write", "activate", "abort", "rollback"].contains(request.operation),
              request.expectedCurrent.map({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) ?? (request.operation != "rollback"),
              request.upload.map({ $0.count == 32 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) ?? true,
              request.sha256.map({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) ?? true,
              request.bytes.map({ (1...maximumArtifactBytes).contains($0) }) ?? true,
              request.offset.map({ (0..<maximumArtifactBytes).contains($0) }) ?? true,
              request.content.map({ $0.utf8.count <= 44_000 && Data(base64Encoded: $0).map { $0.count <= chunkBytes } == true }) ?? true
        else { throw AgentLifecycleIntegrationInstallError.verificationFailed("invalid artifact request") }
        let encoder = JSONEncoder()
        // A binary chunk can encode almost entirely as '/'. Escaping every
        // slash can double the request and exceed the bounded stdin frame.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let stamped = Request(
            operation: request.operation, upload: request.upload, sha256: request.sha256,
            bytes: request.bytes, offset: request.offset, content: request.content,
            expectedCurrent: request.expectedCurrent,
            integration: RemoteAgentLifecycleIntegrationInstaller.integrationVersion
        )
        let payload = try encoder.encode(stamped).base64EncodedString()
        return "python3 -c " + quote(program) + " <<'TESSERA_ARTIFACT_REQUEST'\n" + payload + "\nTESSERA_ARTIFACT_REQUEST"
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static let program = #"""
import base64,fcntl,hashlib,json,os,platform,pwd,re,select,signal,stat,subprocess,sys,time
payload=sys.stdin.buffer.read(65537)
if len(payload)>65536: raise RuntimeError('invalidArtifact')
request=json.loads(base64.b64decode(payload.strip(),validate=True))
operation=request['operation']
def emit(**fields): print(json.dumps(fields,separators=(',',':')))
home=pwd.getpwuid(os.geteuid()).pw_dir
ours=request.get('integration')
if type(ours) is not int: raise RuntimeError('invalidArtifact')
def installed_integration():
    # The lifecycle hook is the installation's manifest. Only the owner's own
    # regular-file hook may claim a version; a symlink or another user's file
    # is this app's to repair. Mode bits are the owner's business.
    try:
        base=os.path.join(home,'.config/tessera')
        info=os.stat(base,follow_symlinks=False)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.geteuid(): return 0
        hook=os.open(os.path.join(base,'agent-lifecycle-hook.sh'),os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        try:
            info=os.fstat(hook)
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid(): return 0
            head=os.read(hook,4096)
        finally: os.close(hook)
    except OSError: return 0
    found=re.search(rb'^TESSERA_AGENT_INTEGRATION_VERSION=([0-9]{1,5})$',head,re.M)
    return int(found.group(1)) if found and int(found.group(1))<=65535 else 0
if operation=='probe':
    system=platform.system(); arch=platform.machine()
    target={('Darwin','arm64'):'darwin-arm64',('Darwin','x86_64'):'darwin-x86_64',('Linux','aarch64'):'linux-aarch64',('Linux','x86_64'):'linux-x86_64'}.get((system,arch))
    release=platform.mac_ver()[0] if system=='Darwin' else platform.release()
    numbers=re.match(r'^(\d+)\.(\d+)',release)
    minimum=(12,0) if system=='Darwin' else (4,19)
    if not target or not numbers or tuple(map(int,numbers.groups()))<minimum: raise RuntimeError('unsupportedTarget')
    # Apps check this before uploading; activation re-checks it under lock.
    emit(target=target,newerIntegration=installed_integration()>ours); raise SystemExit(0)
upload=request['upload']; digest=request['sha256']; size=request['bytes']
if not re.fullmatch('[0-9a-f]{32}',upload) or not re.fullmatch('[0-9a-f]{64}',digest) or not 0<size<=16777216: raise RuntimeError('invalidArtifact')
def directory(parent,name,mode=0o700):
    try: os.mkdir(name,mode,dir_fd=parent)
    except FileExistsError: pass
    fd=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
    info=os.fstat(fd)
    if info.st_uid!=os.geteuid(): os.close(fd); raise RuntimeError('insecureDirectory')
    return fd
homefd=os.open(home,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
config=directory(homefd,'.config'); root=directory(config,'tessera')
versions=directory(root,'agent-host-versions'); staging=directory(root,'agent-host-staging')
runtime=directory(root,'agent-host'); os.fchmod(runtime,0o700)
def regular(parent,name,flags,mode=0o600):
    fd=os.open(name,flags|os.O_NOFOLLOW|os.O_NONBLOCK,mode,dir_fd=parent)
    info=os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_nlink!=1:
        os.close(fd); raise RuntimeError('insecureFile')
    return fd
def hashfile(fd):
    os.lseek(fd,0,0); h=hashlib.sha256(); count=0
    while True:
        data=os.read(fd,65536)
        if not data: break
        count+=len(data)
        if count>16777216: raise RuntimeError('artifactBudget')
        h.update(data)
    return h.hexdigest(),count
def current(name='tessera-agent-host'):
    try: value=os.readlink(name,dir_fd=root)
    except FileNotFoundError: return ''
    if not re.fullmatch('agent-host-versions/[0-9a-f]{64}',value): raise RuntimeError('unrecognizedInstallation')
    return value
def metadata():
    meta=regular(staging,upload+'.json',os.O_RDONLY)
    try: saved=json.loads(os.read(meta,1024))
    finally: os.close(meta)
    if saved['sha256']!=digest or saved['bytes']!=size: raise RuntimeError('uploadMismatch')
    return saved
def shared_lock():
    lock=regular(root,'agent-host-install.lock',os.O_RDWR|os.O_CREAT)
    deadline=time.monotonic()+2
    while True:
        try:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            recover_publication()
            return lock
        except BlockingIOError:
            if time.monotonic()>=deadline: raise RuntimeError('installationBusy')
            time.sleep(.01)
def clear_staging():
    # Caller holds the installation lock. A concurrent writer owns the same
    # payload flock, so cleanup cannot race a chunk append or validation.
    try:
        payload=regular(staging,upload,os.O_RDONLY)
        fcntl.flock(payload,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except FileNotFoundError: payload=None
    try:
        for name in (upload,upload+'.json'):
            try:
                fd=regular(staging,name,os.O_RDONLY); os.close(fd); os.unlink(name,dir_fd=staging)
            except FileNotFoundError: pass
        os.fsync(staging)
    finally:
        if payload is not None: os.close(payload)
def activate_link(name,target):
    temporary=name+'.'+upload
    try: os.symlink(target,temporary,dir_fd=root)
    except FileExistsError:
        info=os.stat(temporary,dir_fd=root,follow_symlinks=False)
        if not stat.S_ISLNK(info.st_mode) or info.st_uid!=os.geteuid() or os.readlink(temporary,dir_fd=root)!=target:
            raise RuntimeError('publicationConflict')
    os.replace(temporary,name,src_dir_fd=root,dst_dir_fd=root)
def recover_publication():
    # One durable transaction covers both links. Any later installer finishes
    # it under the same lock before taking a new compare-and-swap snapshot.
    try: fd=regular(root,'agent-host-publication.json',os.O_RDONLY)
    except FileNotFoundError: return
    try: saved=json.loads(os.read(fd,4097))
    finally: os.close(fd)
    if not isinstance(saved,dict) or saved.get('owner')!='tessera-agent-host-publication-v1': raise RuntimeError('publicationConflict')
    old=saved.get('old',''); desired=saved.get('desired',''); prior=saved.get('priorPrevious','')
    for value in (old,desired,prior):
        if not isinstance(value,str) or (value and not re.fullmatch('agent-host-versions/[0-9a-f]{64}',value)): raise RuntimeError('publicationConflict')
    if not desired or current() not in (old,desired) or current('tessera-agent-host.previous') not in (prior,old): raise RuntimeError('publicationConflict')
    for value in (old,desired):
        if not value: continue
        fd=regular(versions,value.split('/')[1],os.O_RDONLY)
        try:
            if hashfile(fd)[0]!=value.split('/')[1] or not os.fstat(fd).st_mode&0o100: raise RuntimeError('installedChecksumMismatch')
        finally: os.close(fd)
    if old: activate_link('tessera-agent-host.previous',old)
    activate_link('tessera-agent-host',desired); os.fsync(root)
    os.unlink('agent-host-publication.json',dir_fd=root); os.fsync(root)
def publish(desired,old):
    saved=json.dumps({'owner':'tessera-agent-host-publication-v1','old':old,'desired':desired,'priorPrevious':current('tessera-agent-host.previous')},sort_keys=True).encode()
    temporary='agent-host-publication.'+upload
    fd=regular(root,temporary,os.O_RDWR|os.O_CREAT)
    try:
        existing=os.read(fd,4097)
        # A crash can leave a strict prefix before the atomic rename. Resume
        # only this nonce's exact expected journal, never unrelated contents.
        if existing and not saved.startswith(existing): raise RuntimeError('publicationConflict')
        os.lseek(fd,0,0)
        remaining=saved
        while remaining:
            count=os.write(fd,remaining)
            if count<=0: raise RuntimeError('shortWrite')
            remaining=remaining[count:]
        os.fsync(fd)
    finally: os.close(fd)
    os.replace(temporary,'agent-host-publication.json',src_dir_fd=root,dst_dir_fd=root); os.fsync(root)
    recover_publication()
def collect_expired_uploads():
    # Only self-identifying, expired Tessera upload pairs are eligible. Unknown
    # names, symlinks, active writers and recent uploads remain untouched.
    now=time.time()
    with os.scandir(staging) as entries:
        for _,entry in zip(range(128),entries):
            if not re.fullmatch('[0-9a-f]{32}\\.json',entry.name) or entry.name==upload+'.json': continue
            meta=None; payload=None
            try:
                meta=regular(staging,entry.name,os.O_RDONLY)
                saved=json.loads(os.read(meta,1024)); info=os.fstat(meta)
                if not isinstance(saved,dict): continue
                if saved.get('owner')!='tessera-agent-host-upload-v1' or not isinstance(saved.get('created'),(int,float)): continue
                if now-saved['created']<86400 or now-info.st_mtime<86400: continue
                if not re.fullmatch('[0-9a-f]{64}',saved.get('sha256','')) or not 0<saved.get('bytes',0)<=16777216: continue
                name=entry.name[:-5]
                try:
                    payload=regular(staging,name,os.O_RDONLY)
                    fcntl.flock(payload,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    if now-os.fstat(payload).st_mtime<86400: continue
                    os.unlink(name,dir_fd=staging)
                except FileNotFoundError: pass
                os.unlink(entry.name,dir_fd=staging)
            except (OSError,ValueError,TypeError,RuntimeError): pass
            finally:
                if payload is not None: os.close(payload)
                if meta is not None: os.close(meta)
    os.fsync(staging)
def collect_obsolete_versions():
    # Shared installer lock is held. Never remove current/rollback versions,
    # recent binaries, unknown files, or versions pinned by a running service.
    keep={digest,current().split('/')[-1],current('tessera-agent-host.previous').split('/')[-1]}
    now=time.time()
    with os.scandir(versions) as entries:
        for _,entry in zip(range(128),entries):
            if entry.name in keep or not re.fullmatch('[0-9a-f]{64}',entry.name): continue
            fd=None
            try:
                fd=regular(versions,entry.name,os.O_RDONLY)
                info=os.fstat(fd)
                if now-info.st_mtime<86400 or not info.st_mode&0o100: continue
                fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                if hashfile(fd)[0]!=entry.name: continue
                current_info=os.stat(entry.name,dir_fd=versions,follow_symlinks=False)
                if (current_info.st_dev,current_info.st_ino)!=(info.st_dev,info.st_ino): continue
                os.unlink(entry.name,dir_fd=versions)
            except (OSError,ValueError,TypeError,RuntimeError): pass
            finally:
                if fd is not None: os.close(fd)
    os.fsync(versions)
if operation=='begin':
    # A private, unique upload makes simultaneous apps independent. Only the
    # short activation transaction locks shared state.
    lock=shared_lock()
    collect_expired_uploads()
    try:
        fd=regular(staging,upload,os.O_RDWR)
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        metadata()
        if os.fstat(fd).st_size>size: raise RuntimeError('artifactBudget')
        os.close(fd); emit(ready=True); raise SystemExit(0)
    except FileNotFoundError: pass
    with os.scandir(staging) as entries:
        if sum(1 for _,entry in zip(range(17),entries))>=16: raise RuntimeError('stagingBudget')
    fd=regular(staging,upload,os.O_RDWR|os.O_CREAT|os.O_EXCL); os.close(fd)
    metadata=regular(staging,upload+'.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL)
    os.write(metadata,json.dumps({'current':current(),'sha256':digest,'bytes':size,'owner':'tessera-agent-host-upload-v1','created':time.time()}).encode()); os.fsync(metadata); os.close(metadata)
    emit(ready=True)
elif operation=='write':
    offset=request['offset']; data=base64.b64decode(request['content'],validate=True)
    if not isinstance(offset,int) or offset<0 or not 0<len(data)<=32768 or offset+len(data)>size: raise RuntimeError('invalidChunk')
    fd=regular(staging,upload,os.O_RDWR)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    metadata()
    length=os.fstat(fd).st_size
    if length==offset:
        os.lseek(fd,offset,0)
        while data:
            count=os.write(fd,data)
            if count<=0: raise RuntimeError('shortWrite')
            data=data[count:]
    elif length>=offset+len(data):
        os.lseek(fd,offset,0)
        if os.read(fd,len(data))!=data: raise RuntimeError('chunkConflict')
    else: raise RuntimeError('chunkGap')
    os.close(fd); emit(written=True)
elif operation=='activate':
    lock=shared_lock()
    desired='agent-host-versions/'+digest
    if current()==desired:
        fd=regular(versions,digest,os.O_RDONLY)
        if hashfile(fd)!=(digest,size) or not os.fstat(fd).st_mode&0o100: raise RuntimeError('installedChecksumMismatch')
        os.close(fd); clear_staging(); emit(installed=True,sha256=digest); raise SystemExit(0)
    # Never re-point the host backwards underneath a newer app's scripts.
    if installed_integration()>ours: raise RuntimeError('newerIntegrationInstalled')
    try: fd=regular(staging,upload,os.O_RDONLY)
    except FileNotFoundError: fd=regular(versions,digest,os.O_RDONLY)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    if hashfile(fd)!=(digest,size): raise RuntimeError('checksumMismatch')
    saved=metadata()
    active=current()
    current('tessera-agent-host.previous')
    if active not in (saved['current'],desired): raise RuntimeError('installationChanged')
    os.fchmod(fd,0o700); os.fsync(fd)
    executable=os.path.join(home,'.config/tessera/agent-host-staging',upload)
    if not os.path.exists(executable): executable=os.path.join(home,'.config/tessera',desired)
    # The shell remains an unreaped owned session leader while waiting for
    # private stdin. Works with stock macOS Python lacking os.waitid.
    wrapper='"$1" --version; _tessera_status=$?; printf "\\nTESSERA_EXIT=%s\\n" "$_tessera_status"; read _tessera_release'
    child=subprocess.Popen(['/bin/sh','-c',wrapper,'tessera-verify',executable],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    output=bytearray(); deadline=time.monotonic()+2
    try:
        while time.monotonic()<deadline:
            if not select.select([child.stdout],[],[],max(0,deadline-time.monotonic()))[0]: break
            data=os.read(child.stdout.fileno(),4097-len(output))
            if not data: break
            output.extend(data)
            if len(output)>4096: raise RuntimeError('verificationOutputBudget')
            if b'\nTESSERA_EXIT=' in output and output.endswith(b'\n'): break
        if time.monotonic()>=deadline: raise RuntimeError('verificationDeadline')
        if output!=b'tessera-agent-host 0.1.0\n\nTESSERA_EXIT=0\n': raise RuntimeError('executableVerificationFailed')
    finally:
        try: os.killpg(child.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        child.wait(timeout=2); child.stdout.close(); child.stdin.close()
    try:
        existing=regular(versions,digest,os.O_RDONLY)
        if hashfile(existing)!=(digest,size) or not os.fstat(existing).st_mode&0o100: raise RuntimeError('installedChecksumMismatch')
        os.close(existing)
    except FileNotFoundError:
        collect_obsolete_versions()
        with os.scandir(versions) as entries:
            if sum(1 for _,entry in zip(range(9),entries))>=8: raise RuntimeError('versionStorageBudget')
        os.rename(upload,digest,src_dir_fd=staging,dst_dir_fd=versions)
        os.fsync(versions)
    os.close(fd)
    publish(desired,active)
    clear_staging()
    emit(installed=True,sha256=digest)
elif operation=='rollback':
    expected=request.get('expectedCurrent','')
    if not re.fullmatch('[0-9a-f]{64}',expected): raise RuntimeError('invalidRollback')
    lock=shared_lock(); desired='agent-host-versions/'+digest; active=current()
    if active!=desired:
        if active!='agent-host-versions/'+expected or current('tessera-agent-host.previous')!=desired:
            raise RuntimeError('installationChanged')
    fd=regular(versions,digest,os.O_RDONLY)
    try:
        if hashfile(fd)!=(digest,size) or not os.fstat(fd).st_mode&0o100: raise RuntimeError('installedChecksumMismatch')
    finally: os.close(fd)
    if active!=desired:
        publish(desired,active)
    emit(installed=True,rolledBack=True,sha256=digest)
elif operation=='abort':
    # Delete only this invocation's validated staging filenames, never a glob.
    shared=shared_lock()
    clear_staging()
    emit(stagingCleared=True,installed=current()=='agent-host-versions/'+digest)
else: raise RuntimeError('invalidOperation')
"""#
}
