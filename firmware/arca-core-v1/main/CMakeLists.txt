idf_component_register(
    SRCS
        "arca_main.c"
        "arca_state.c"
        "arca_buttons.c"
        "arca_wav.c"
        "arca_recorder.c"
        "arca_storage.c"
        "arca_uploader.c"
        "arca_adpcm.c"
        "arca_ble.c"
        "arca_face.c"
        "arca_clock.c"
        "arca_power.c"
    INCLUDE_DIRS "."
    REQUIRES
        # board support
        bsp_extra              # copied from Waveshare's examples, see README
        # platform
        driver
        esp_timer
        esp_driver_i2c
        fatfs
        vfs
        nvs_flash
        json                   # cJSON, for config.json and the sidecars
        # networking
        esp_wifi
        esp_netif
        esp_event
        esp_http_client
        esp-tls
        mbedtls
        # bluetooth
        bt
)
