import json,sys,os,glob
f=sorted(glob.glob(os.path.expanduser('~/Library/Logs/DiagnosticReports/%s-*.ips'%sys.argv[1])),key=os.path.getmtime)[-1]
print(f)
t=open(f).read().split('\n',1); d=json.loads(t[1])
print(d.get('exception'), d.get('termination',{}).get('indicator'), d.get('asi'))
th=[x for x in d['threads'] if x.get('triggered')][0]; imgs=d['usedImages']
for fr in th['frames'][:int(sys.argv[2]) if len(sys.argv)>2 else 20]:
  print(imgs[fr['imageIndex']].get('name'), fr.get('symbol'), fr.get('symbolLocation'))
