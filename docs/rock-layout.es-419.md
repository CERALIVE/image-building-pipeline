# Almacenamiento de ROCK 5B+

ROCK 5B+ necesita una tarjeta de 16 GB o más. Usa dos particiones raíz de 4 GiB, una partición de arranque de 256 MiB y datos que se amplían en el primer arranque. Las actualizaciones firmadas requieren la geometría correspondiente. Cada raíz debe conservar al menos 512 MiB libres reales. La publicación requiere compilar la imagen completa y verificar arranque, datos, actualización firmada y reversión en hardware.

## Capacidad mínima medida

La verificación previa a la grabación, la ampliación del primer arranque y la comprobación de datos comparan el tamaño medido del medio con 15,000,000,000 bytes (unos 13.97 GiB). Las tarjetas vendidas como 16 GB tienen menos de lo que indica la etiqueta: las mediciones publicadas van de unos 15.48 GB (14.42 GiB) a 15.93 GB (14.84 GiB). El mínimo queda alrededor de un 3 % por debajo de la menor, así que las tarjetas de 16 GB genuinas pasan. En el mínimo, el espacio del cargador de 16 MiB, la partición de arranque, las dos raíces y la cola de GPT ocupan 8,465 MiB y dejan unos 5,840 MiB (5.7 GiB) para datos y actualizaciones. La reserva de 512 MiB está dentro de cada raíz.
