# La caja no puede iniciar de forma segura

[English](attention.md#storage-cannot-start-safely-fork-topic).

Tema del fork, pendiente de validación física. La imagen ROCK actual necesita
una tarjeta de 16 GB o más. El mínimo medido es 15,000,000,000 bytes, por
debajo del tamaño medido de las tarjetas de 16 GB genuinas.
Antes de modificar las particiones, se rechaza una tarjeta demasiado pequeña
o de solo lectura. Si falla ese paso, no se monta ni se amplía `/data`, no se ejecuta su comprobación con reparación automática
y no se migra la configuración. El arranque continúa con el diagnóstico independiente.

La migración también requiere que termine con éxito la ampliación del sistema
de archivos antes de crear datos o habilitar los montajes de escritura de la
aplicación, los registros y los perfiles de NetworkManager. Si falla esa
ampliación, esos servicios no escriben y el diagnóstico independiente muestra
el error fatal de almacenamiento.

El LED de estado parpadea un segundo encendido y tres apagado. HDMI muestra
el motivo y la solución en VT8; Alt+F1 abre la consola de acceso. La página
HTTP local ofrece la misma información, sin acciones de escritura:

- Tarjeta demasiado pequeña: usa una vendida como 16 GB o más y vuelve a
  prepararla con la imagen.
- La caja no pudo preparar su almacenamiento: usa la recuperación local para
  revisar el sistema de archivos o vuelve a preparar la tarjeta con la imagen.
  Si el problema persiste, prepara otra tarjeta.
- Solo lectura: revisa el seguro del adaptador. Si sigue así, cambia la tarjeta.
- Error de ampliación: revisa la tarjeta mediante recuperación local antes de
  reiniciar manualmente.

La aplicación de configuración puede consultar por HTTP, puerto 80,
`/attention/status.json` (`highest.id` igual a `data-readiness`, gravedad
`fatal`). GET/HEAD `/` y `/attention/` muestran la página. No se necesitan
credenciales, TLS ni `/data`. Se conserva la red existente; no se crea un
punto de acceso de recuperación. No hay reparación ni reinicio automático,
confirmación de ranuras ni restablecimiento de intentos A/B.

Los diagnósticos solo escriben en `/run`. No es una prueba completa de capacidad:
una tarjeta falsa que devuelve lecturas aparentemente válidas puede pasar.
Faltan las pruebas físicas de LED, HDMI, red local, rechazo, recuperación y
retorno a la consola en una tarjeta de repuesto antes de publicar una imagen.
