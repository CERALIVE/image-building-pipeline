"""Minimal NetworkManager D-Bus fixture, on an explicitly private test bus."""
import json
import sys
import socket
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.bus.BusConnection(sys.argv[1])
name = dbus.service.BusName('org.freedesktop.NetworkManager', bus)
state_path = sys.argv[2]
base = '/org/freedesktop/NetworkManager'
class Object(dbus.service.Object):
    @dbus.service.method('org.freedesktop.NetworkManager', out_signature='ao')
    def GetDevices(self):
        return [base+'/Devices/1', base+'/Devices/2']

    @dbus.service.method('org.freedesktop.DBus.Properties', in_signature='s', out_signature='a{sv}')
    def GetAll(self, interface):
        i = self.__dbus_object_path__[-1]
        snapshot = json.load(open(state_path))
        state = snapshot[i]
        if interface.endswith('.Device'):
            return dict(DeviceType=dbus.UInt32(8),State=dbus.UInt32(state),IpInterface='cell.'+i,
                        Ip6Config=dbus.ObjectPath('/' if snapshot.get('ipv4_only') and i=='1' else base+'/IP6Config/'+i))
        return dict(Gateway=f'fd51:{i}::2', Nameservers=dbus.Array([
            dbus.ByteArray(socket.inet_pton(socket.AF_INET6, f'fd51:{i}::2'))], signature='ay'))

    @dbus.service.signal('org.freedesktop.DBus.Properties', signature='sa{sv}as')
    def PropertiesChanged(self, interface, changed, invalidated): pass

objects = [Object(bus, base)]
for i in ['1','2']:
    objects.extend([Object(bus,base+'/Devices/'+i),Object(bus,base+'/IP6Config/'+i)])
previous = [None]
def tick():
    snapshot = open(state_path).read()
    if snapshot == previous[0]:
        return True
    previous[0] = snapshot
    objects[0].PropertiesChanged('org.freedesktop.NetworkManager',{},[])
    return True
GLib.timeout_add(200,tick)
GLib.MainLoop().run()
