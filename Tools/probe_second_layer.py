#!/usr/bin/env python3
# Run the first-layer decoder in-process, then test common string ciphers
# against UI plaintexts observed in the real Drive World gate.
from pathlib import Path

ns={}
exec(Path('Tools/decode_script_lua.py').read_text(), ns)
decoded=ns['decoded']

printable=[]
for i,b in enumerate(decoded,1):
    if b and all(32 <= x <= 126 for x in b):
        printable.append((i,b))

known=[
    b'SCRIPT ACCESS',
    b'Enter your access key to continue',
    b'ACCESS-KEY',
    b'GET KEY',
    b'UNLOCK',
    b'Copied to clipboard.',
    b'Access granted.',
    b'Invalid key.',
    b'UNLOCKED',
    b'LoaderKeySystem',
]

def rc4(data,key):
    if not key: return b''
    S=list(range(256)); j=0
    for i in range(256):
        j=(j+S[i]+key[i%len(key)])&255; S[i],S[j]=S[j],S[i]
    out=bytearray(); i=j=0
    for c in data:
        i=(i+1)&255; j=(j+S[i])&255; S[i],S[j]=S[j],S[i]
        out.append(c ^ S[(S[i]+S[j])&255])
    return bytes(out)

def rep(data,key,op):
    out=bytearray()
    for i,c in enumerate(data):
        k=key[i%len(key)]
        if op=='xor': x=c^k
        elif op=='sub': x=(c-k)&255
        elif op=='add': x=(c+k)&255
        elif op=='rsub': x=(k-c)&255
        out.append(x)
    return bytes(out)

hits=[]
for ci,c in enumerate(decoded,1):
    for ki,key in printable:
        for rev in (False,True):
            k=key[::-1] if rev else key
            for op in ('xor','sub','add','rsub'):
                try: p=rep(c,k,op)
                except: continue
                if p in known:
                    hits.append((ci,ki,op,rev,p))
            try:
                p=rc4(c,k)
                if p in known: hits.append((ci,ki,'rc4',rev,p))
            except: pass

print('=== EXACT KNOWN-PLAINTEXT HITS ===')
for h in hits: print(h)
if not hits: print('NONE')

# Single-byte affine/XOR checks for same-length known values.
print('=== SAME-LENGTH BYTE DELTA PROFILES ===')
for pt in known:
    for ci,c in enumerate(decoded,1):
        if len(c)!=len(pt): continue
        xors={a^b for a,b in zip(c,pt)}
        subs={(a-b)&255 for a,b in zip(c,pt)}
        if len(xors)<=2 or len(subs)<=2:
            print('candidate',ci,'plain',pt,'xor_values',sorted(xors),'sub_values',sorted(subs),'cipher',c.hex())
