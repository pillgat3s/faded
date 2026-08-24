#!/usr/bin/env python3
"""Measures whether the driver produces audio at real time.

Runs three concurrent silent players and compares the ring's write index
against the wall clock. Anything but ~0% error means the consumer is being fed
at the wrong speed, which is heard as robotic, stuttering audio rather than as
a clean dropout. Three players specifically, because the HAL delivers one
buffer per *client* per cycle: a writer that advances once per call rather than
once per frame position runs at N times real time and only misbehaves when more
than one app is playing.

Faded.app may be running; this only observes.
"""
# Measures the producer clock, counting ONLY intervals where the device is
# actually running. Faded.app is not running, so nothing consumes the ring.
import ctypes, ctypes.util, struct, os, time, subprocess
ca=ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreAudio"))
cf=ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
libc=ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
class A(ctypes.Structure): _fields_=[("sel",ctypes.c_uint32),("scope",ctypes.c_uint32),("elem",ctypes.c_uint32)]
def f(s): return int.from_bytes(s.encode(),"big")
cf.CFStringCreateWithCString.restype=ctypes.c_void_p
def get_default():
    a=A(f("dOut"),f("glob"),0); v=ctypes.c_uint32(); s=ctypes.c_uint32(4)
    ca.AudioObjectGetPropertyData(1,ctypes.byref(a),0,None,ctypes.byref(s),ctypes.byref(v)); return v.value
def set_default(d):
    a=A(f("dOut"),f("glob"),0); v=ctypes.c_uint32(d)
    return ca.AudioObjectSetPropertyData(1,ctypes.byref(a),0,None,4,ctypes.byref(v))
def by_uid(u):
    a=A(f("uidd"),f("glob"),0); d=ctypes.c_uint32(0); sz=ctypes.c_uint32(4)
    cs=cf.CFStringCreateWithCString(None,u.encode(),0x08000100); inp=ctypes.c_void_p(cs)
    ca.AudioObjectGetPropertyData(1,ctypes.byref(a),ctypes.sizeof(inp),ctypes.byref(inp),ctypes.byref(sz),ctypes.byref(d)); return d.value
def rate_of(d):
    a=A(f("nsrt"),f("glob"),0); v=ctypes.c_double(); s=ctypes.c_uint32(8)
    ca.AudioObjectGetPropertyData(d,ctypes.byref(a),0,None,ctypes.byref(s),ctypes.byref(v)); return v.value
libc.shm_open.argtypes=[ctypes.c_char_p,ctypes.c_int,ctypes.c_int]; libc.shm_open.restype=ctypes.c_int
libc.mmap.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_longlong]; libc.mmap.restype=ctypes.c_void_p
fd=libc.shm_open(b"/com.andri.faded.ring",0,0); addr=libc.mmap(None,os.fstat(fd).st_size,1,1,fd,0)
def snap():
    b=ctypes.string_at(addr+16,16)
    w,=struct.unpack_from("<Q",b,0); rate,run=struct.unpack_from("<II",b,8); return w,rate,run

orig=get_default(); faded=by_uid("com.andri.faded.output")
try:
    set_default(faded); time.sleep(0.5)
    ps=[subprocess.Popen(["afplay", os.path.join(os.path.dirname(__file__),"hold.wav")]) for _ in range(3)]
    p=ps[0]
    time.sleep(1.5)
    dev_rate=rate_of(faded)
    samples=[]
    t_prev=time.monotonic(); w_prev,_,_=snap()
    for _ in range(90):
        time.sleep(0.1)
        t=time.monotonic(); w,ring_rate,run=snap()
        if run and w>w_prev: samples.append((w-w_prev, t-t_prev))
        t_prev, w_prev = t, w
    [q.terminate() for q in ps]
    frames=sum(a for a,_ in samples); secs=sum(b for _,b in samples)
    print("THREE concurrent players — the condition that produced 2x")
    print(f"device nominal rate : {dev_rate:.1f} Hz")
    print(f"ring publishes      : {ring_rate} Hz")
    print(f"active intervals    : {len(samples)}  ({secs:.2f} s counted)")
    if secs>1:
        measured=frames/secs
        print(f"measured producer   : {measured:.1f} frames/s")
        err=(measured/dev_rate-1)*100
        print(f"error vs nominal    : {err:+.2f} %")
        print("PRODUCER IS REAL-TIME AND CONSISTENT" if abs(err)<1.0 else ">>> STILL WRONG <<<")
finally:
    set_default(orig); time.sleep(0.3)
