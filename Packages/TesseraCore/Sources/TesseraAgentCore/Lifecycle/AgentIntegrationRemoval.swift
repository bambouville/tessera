import Foundation

extension RemoteAgentLifecycleIntegrationInstaller {
    /// An explicit, host-local removal entry point shared by both platforms.
    /// Validate every config before changing any; retain helper files on failure.
    public static var uninstallScript: String {
        let markers = [rcMarkerLine, bashLoginMarkerLine]
        let encoded = (try! JSONEncoder().encode(markers)).base64EncodedString()
        return "#!/bin/sh\n# Tessera Agent Center removal. Close running agents first.\npython3 - <<'TESSERA_REMOVE'\n" +
            removalProgram.replacingOccurrences(of: "__RC_MARKERS__", with: encoded) + "\nTESSERA_REMOVE\n"
    }

    static let removalProgram = #"""
import base64,fcntl,hashlib,json,os,re,stat,tempfile
home=os.path.realpath(os.path.expanduser('~'))
root=os.path.join(home,'.config/tessera')
markers=set(json.loads(base64.b64decode('__RC_MARKERS__')))
changes=[]
def read(path):
    if not os.path.lexists(path): return None
    resolved=os.path.realpath(path)
    fd=os.open(resolved,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_nlink!=1 or info.st_size>1048576: raise RuntimeError('unsafe configuration')
        data=os.read(fd,1048577)
        if len(data)>1048576: raise RuntimeError('configuration budget')
        return resolved,data,info.st_mode&0o777
    finally: os.close(fd)
def stage(path,transform):
    current=read(path)
    if current is None: return
    resolved,data,mode=current
    updated=transform(data.decode('utf-8')).encode('utf-8')
    if updated!=data: changes.append((path,resolved,data,updated,mode))
def owned(handler,provider,event):
    if not isinstance(handler,dict) or handler.get('type')!='command': return False
    command=handler.get('command','')
    if provider=='claude' and command=='"$HOME/.config/tessera/tessera-agent-host" hook --runtime-base "$HOME/.config/tessera/agent-host"': return True
    return re.fullmatch(r'"\$HOME/\.config/tessera/agent-lifecycle-hook\.sh" '+re.escape(provider)+' '+re.escape(event)+r' (waitingForInput|working|idle|unavailable) [a-z][a-z-]{0,63}',command) is not None
def clean_json(text,provider):
    def unique(pairs):
        result={}
        for key,value in pairs:
            if key in result: raise RuntimeError('duplicate provider configuration key')
            result[key]=value
        return result
    config=json.loads(text,object_pairs_hook=unique)
    original=json.dumps(config,ensure_ascii=False,sort_keys=True)
    if not isinstance(config,dict): raise RuntimeError('invalid provider configuration')
    hooks=config.get('hooks',{})
    if not isinstance(hooks,dict): raise RuntimeError('invalid provider hooks')
    for event,groups in list(hooks.items()):
        if not isinstance(groups,list): raise RuntimeError('invalid provider hook group')
        kept=[]
        for group in groups:
            if not isinstance(group,dict) or not isinstance(group.get('hooks'),list):
                kept.append(group); continue
            handlers=[h for h in group['hooks'] if not owned(h,provider,event)]
            if handlers==group['hooks']: kept.append(group)
            elif handlers: kept.append(dict(group,hooks=handlers))
        if kept: hooks[event]=kept
        else: hooks.pop(event,None)
    return text if json.dumps(config,ensure_ascii=False,sort_keys=True)==original else json.dumps(config,ensure_ascii=False,indent=2)+'\n'
def clean_kimi(text):
    start='# TESSERA-AGENT-CENTER-KIMI-HOOKS-BEGIN'; end='# TESSERA-AGENT-CENTER-KIMI-HOOKS-END'
    lines=text.splitlines(keepends=True); inside=False; seen=False; result=[]
    for line in lines:
        if line.rstrip('\r\n')==start:
            if inside or seen: raise RuntimeError('ambiguous Kimi markers')
            inside=True; seen=True
        elif line.rstrip('\r\n')==end:
            if not inside: raise RuntimeError('ambiguous Kimi markers')
            inside=False
        elif not inside: result.append(line)
    if inside: raise RuntimeError('incomplete Kimi markers')
    return ''.join(result)
for provider,directory,filename in [('codex',os.environ.get('CODEX_HOME') or home+'/.codex','hooks.json'),('claude',os.environ.get('CLAUDE_CONFIG_DIR') or home+'/.claude','settings.json')]:
    stage(os.path.join(directory,filename),lambda text,p=provider:clean_json(text,p))
stage(os.path.join(os.environ.get('KIMI_CODE_HOME') or home+'/.kimi-code','config.toml'),clean_kimi)
for path in {home+'/.bashrc',home+'/.bash_profile',home+'/.bash_login',home+'/.profile',(os.environ.get('ZDOTDIR') or home)+'/.zshrc'}:
    stage(path,lambda text:''.join(line for line in text.splitlines(keepends=True) if line.rstrip('\r\n') not in markers))
# Compare-and-swap each prepared edit. Any failure retains support files, so a
# partially completed removal is safe to retry and remaining hooks still work.
for original,path,before,after,mode in changes:
    if os.path.realpath(original)!=path or read(original)[1]!=before: raise RuntimeError('configuration changed; retry removal')
    fd,tmp=tempfile.mkstemp(prefix='.tessera-remove-',dir=os.path.dirname(path))
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'wb') as stream: stream.write(after); stream.flush(); os.fsync(stream.fileno())
        if os.path.realpath(original)!=path or read(original)[1]!=before: raise RuntimeError('configuration changed; retry removal')
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
# Never recursively delete the user's configuration directory. Only named
# integration files and digest-verified, unlocked versions belong to removal.
if os.path.lexists(root):
    info=os.lstat(root)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.geteuid(): raise RuntimeError('unsafe integration directory')
    for name in ['agent-lifecycle-hook.sh','agent-launch.sh','tessera-agent-project','tessera-agent-launch','tessera-agent-prove','agent-codex-readiness.sh','agent-codex-recover.sh','agent-lifecycle.sh','claude-agent-hooks.json','agent-uninstall.sh','bin/claude','bin/codex','tessera-agent-host']:
        path=os.path.join(root,name)
        if os.path.realpath(os.path.dirname(path))!=os.path.dirname(path): continue
        if not os.path.lexists(path): continue
        info=os.lstat(path)
        if info.st_uid==os.geteuid() and (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)): os.unlink(path)
    versions=os.path.join(root,'agent-host-versions')
    if os.path.isdir(versions) and not os.path.islink(versions):
        for name in os.listdir(versions):
            if not re.fullmatch('[0-9a-f]{64}',name): continue
            path=os.path.join(versions,name)
            try:
                fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
                try:
                    info=os.fstat(fd)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_nlink!=1 or info.st_size>16777216: continue
                    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    digest=hashlib.sha256()
                    while True:
                        data=os.read(fd,65536)
                        if not data: break
                        digest.update(data)
                    if digest.hexdigest()==name: os.unlink(path)
                finally: os.close(fd)
            except (BlockingIOError,FileNotFoundError): pass
print('Tessera integration removed. Restart existing shells and agents to clear their loaded hooks and command cache. Active helper versions remain until their processes exit.')
"""#
}
