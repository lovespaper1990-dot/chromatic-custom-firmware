idf_component_register(SRCS "snapshot.c" "slot.c" INCLUDE_DIRS "."
    PRIV_REQUIRES crc fatfs sdmmc esp_driver_sdmmc esp_driver_uart)
