# ROCK 5B+ storage layout

ROCK 5B+ needs a 16 GB card or larger. It uses two 4 GiB root slots, a 256 MiB boot partition and a data partition that grows on first boot. Signed updates require matching root geometry. Each populated root must retain at least 512 MiB actual free space. Release qualification requires a complete image build, first boot, data readiness, signed update and rollback on hardware.

## Measured capacity floor

Preflash, first-boot growth and data readiness compare the measured media size with 15,000,000,000 bytes (about 13.97 GiB). Cards sold as 16 GB hold less than their label: published measurements range from about 15.48 GB (14.42 GiB) to 15.93 GB (14.84 GiB). The floor is about 3% below the smallest of these, so genuine 16 GB cards pass. At the floor, the 16 MiB loader gap, boot partition, both root slots and the GPT tail take 8,465 MiB and leave about 5,840 MiB (5.7 GiB) for data and update staging. The 512 MiB reserve is inside each root slot.
