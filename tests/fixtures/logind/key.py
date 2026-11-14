import os,struct,time,sys
fd=os.open('/dev/input/event0',os.O_WRONLY|os.O_NONBLOCK)
def event(value):
 now=time.monotonic(); sec=int(now); usec=int((now-sec)*1000000)
 os.write(fd,struct.pack('llHHi',sec,usec,1,116,value))
 os.write(fd,struct.pack('llHHi',sec,usec,0,0,0))
event(1)
time.sleep(6 if len(sys.argv)>1 and sys.argv[1]=='long' else .1)
event(0)
os.close(fd)
