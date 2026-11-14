# Registros de fallos después de un reinicio en caliente (borrador)

Un reinicio silencioso puede borrar la pista del fallo. La compilación del kernel
agrega una reserva ramoops de 1 MiB en `0x1f000000` a los árboles de dispositivos
de ROCK 5B y ROCK 5B+. El kernel conserva los últimos mensajes en RAM y el
servicio estándar systemd-pstore los guarda y elimina del pstore al arrancar.
No se modifica `boot.scr`.

El archivo `manifests/kernel/rk3588-ramoops.dtsi` define registros de 128 KiB,
512 KiB de consola y `max-reason=2`. El helper y el archivo son entradas de la
huella del kernel; las revisiones del paquete avanzan para evitar reutilizar
bytes publicados. Se necesita compilar y publicar el kernel correspondiente
antes de ensamblar una imagen de producción; este borrador no lo publica.

`Storage=external` y `Unlink=yes` usan el archivador estándar. El servicio
requiere el montaje de `/data` y la preparación de tmpfiles. Un bind privado
del servicio conecta `/data/ceralive/pstore` con `/var/lib/systemd/pstore`.
Tmpfiles crea el directorio con permisos 0700. Un paso previo mueve los archivos
ramoops existentes a un directorio único antes de que el archivador estándar
reemplace sus nombres. Conserva hasta 31 colecciones anteriores y la actual;
elimina por número de secuencia con ceros iniciales y limita el historial a 44 MiB de
tamaño aparente. La creación exclusiva del directorio reintenta las colisiones.
La hora queda solo como metadato en `collected-at`: indica cuándo los archivos
anteriores se movieron al historial o se reanudó un movimiento interrumpido, no
cuándo los recopiló systemd-pstore. Los retrocesos del reloj y las épocas de
arranque repetidas no afectan la retención. Se eliminan las asignaciones
vacías y los movimientos interrumpidos continúan en la misma generación. La
descompresión de pstore puede producir unos 1.4 MiB desde la reserva de 1 MiB, más la
sobrecarga del sistema de archivos. No se promete conservar cada fallo para
siempre. Tmpfiles no elimina archivos por edad: solo los límites de cantidad y
tamaño eliminan generaciones por secuencia. El cálculo de tamaño incluye
únicamente los directorios de generaciones numeradas. Los archivos sobreviven al cambio
de raíz A/B. Si falta `/data`, el servicio no ejecuta ni borra los registros.

Lectura sin modificar archivos (requiere permisos de root):

```sh
sudo find /data/ceralive/pstore -type f -name '*ramoops*' -exec tail -v -n +1 -- '{}' +
sudo journalctl -u systemd-pstore.service
```

El diario tiene su propia retención; `journalctl -u systemd-pstore.service -o
verbose --all` muestra también el contenido `FILE=`. Después de arrancar sin RTC,
los archivos del diario con esas copias `FILE=` pueden eliminarse antes de tiempo
porque sus primeras entradas son anteriores a la sincronización del reloj.
El archivo en `/data` es la copia duradera.
No hay colector propio, esquema JSON ni lector de último arranque. CeraUI no
consume el lector retirado. Las causas de reinicio de U-Boot y el bootstatus
del watchdog corresponden a un registro de arranque separado.

Falta validar la dirección, reservas de firmware, rangos del cargador y
conservación de RAM en cada tamaño de memoria y combinación kernel/cargador.
El initrd debe terminar antes de `0x1f000000`: desde `0x0a200000`, menos de
334 MiB; desde `0x12180000`, menos de 206.5 MiB. ECC está desactivado;
validar `ecc-size = <16>` y la capacidad reducida antes de activarlo.
Se deben repetir pánicos y reinicios por watchdog y comprobar los archivos y
su eliminación del pstore. Un corte de energía borra RAM; un bloqueo puede
dejar solo la consola. Las pruebas del host no califican hardware.

TODO: otras placas RK3588 (incluida Orange Pi 5 Plus), otras familias ARM y x86
necesitan su propia dirección o backend y pruebas de conservación. No se cambia
la política del watchdog.
