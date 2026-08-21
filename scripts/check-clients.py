#!/usr/bin/env python3
"""Reads the Faded driver's live client list straight from its custom property.

Every app currently feeding the Faded device appears here, with the decaying
peak the driver measured for it. If apps are playing but every peak reads 0,
the per-client callback is not being dispatched — which is exactly the failure
that kept the Apps section of the menu permanently empty.
"""
import ctypes, ctypes.util
ca=ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreAudio"))
cf=ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
class A(ctypes.Structure): _fields_=[("sel",ctypes.c_uint32),("scope",ctypes.c_uint32),("elem",ctypes.c_uint32)]
def f(s): return int.from_bytes(s.encode(),"big")
for fn,res in [("CFArrayGetCount",ctypes.c_long),("CFArrayGetValueAtIndex",ctypes.c_void_p),
               ("CFDictionaryGetValue",ctypes.c_void_p),("CFStringCreateWithCString",ctypes.c_void_p)]:
    getattr(cf,fn).restype=res
cf.CFArrayGetValueAtIndex.argtypes=[ctypes.c_void_p,ctypes.c_long]
cf.CFDictionaryGetValue.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
cf.CFStringGetCString.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_long,ctypes.c_uint32]
cf.CFNumberGetValue.argtypes=[ctypes.c_void_p,ctypes.c_long,ctypes.c_void_p]
def key(s): return cf.CFStringCreateWithCString(None,s.encode(),0x08000100)
def cstr(r):
    b=ctypes.create_string_buffer(256); cf.CFStringGetCString(r,b,256,0x08000100); return b.value.decode()
def num(r):
    v=ctypes.c_double(); cf.CFNumberGetValue(r,13,ctypes.byref(v)); return v.value
a=A(f("uidd"),f("glob"),0); d=ctypes.c_uint32(0); sz=ctypes.c_uint32(4)
inp=ctypes.c_void_p(key("com.andri.faded.output"))
ca.AudioObjectGetPropertyData(1,ctypes.byref(a),ctypes.sizeof(inp),ctypes.byref(inp),ctypes.byref(sz),ctypes.byref(d))
a2=A(f("fcli"),f("glob"),0); arr=ctypes.c_void_p(); s2=ctypes.c_uint32(8)
ok=ca.AudioObjectGetPropertyData(d.value,ctypes.byref(a2),0,None,ctypes.byref(s2),ctypes.byref(arr))
n=cf.CFArrayGetCount(arr) if ok==0 else 0
loud=[]
for i in range(n):
    it=cf.CFArrayGetValueAtIndex(arr,i)
    p=num(cf.CFDictionaryGetValue(it,key("peak")))
    if p>0.0003: loud.append((p,cstr(cf.CFDictionaryGetValue(it,key("bundle")))))
print(f"{n} clients attached; {len(loud)} producing signal")
for p,b in sorted(loud, reverse=True): print(f"   peak={p:.4f}  {b or '(no bundle id)'}")
print("\nPER-APP PIPELINE WORKS" if loud else "\nstill no per-client signal — peaks are not being produced")
