/* Synthetic evdev ioctls only. The real logind consumes FIFO input events.
 * The private tmpfs sysfs fixture reports SYSFS_MAGIC for sd-device validation.
 * No host input nodes or uinput access are needed. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
int ioctl(int fd, unsigned long req, ...) {
 va_list ap; va_start(ap,req); void *arg=va_arg(ap,void*); va_end(ap);
 char p[64], target[256]; snprintf(p,sizeof p,"/proc/self/fd/%d",fd);
 ssize_t n=readlink(p,target,sizeof target-1); if(n>=0)target[n]=0;
 if(n>0 && !strcmp(target,"/dev/input/event0")) {
  size_t size=_IOC_SIZE(req); unsigned nr=_IOC_NR(req);
  if(_IOC_TYPE(req)=='E' && (_IOC_DIR(req)&_IOC_READ)) {
   memset(arg,0,size);
   if(nr==0x20 && size) ((unsigned char*)arg)[0]=2;
   else if(nr==0x21 && size>KEY_POWER/8) ((unsigned char*)arg)[KEY_POWER/8]=1<<(KEY_POWER%8);
   else if(nr==0x06) { snprintf(arg,size,"Synthetic power key"); return 20; }
   return size;
  }
  errno=ENOTTY; return -1;
 }
 static int (*real_ioctl)(int,unsigned long,...); if(!real_ioctl)real_ioctl=dlsym(RTLD_NEXT,"ioctl");
 return real_ioctl(fd,req,arg);
}
#include <sys/vfs.h>
#include <linux/magic.h>
int fstatfs(int fd, struct statfs *buf) {
 static int (*real_fstatfs)(int,struct statfs*); if(!real_fstatfs)real_fstatfs=dlsym(RTLD_NEXT,"fstatfs");
 int r=real_fstatfs(fd,buf);
 char p[64],target[1024]; snprintf(p,sizeof p,"/proc/self/fd/%d",fd);
 ssize_t n=readlink(p,target,sizeof target-1); if(n>=0)target[n]=0;
 if(r==0 && n>0 && (!strncmp(target,"/sys",4)||!strncmp(target,"/var/tmp/logind-contract/sys",strlen("/var/tmp/logind-contract/sys"))))buf->f_type=SYSFS_MAGIC;
 return r;
}
int fstatfs64(int fd, struct statfs64 *buf) { return fstatfs(fd,(struct statfs*)buf); }
