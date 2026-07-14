"""
_compound.py — data for the "add controller" compound operation.

Extracted once from capture 03 (a blank project + one added controller). Holds the generic,
model-INDEPENDENT scaffolding that Composer creates alongside any controller: the location-image
defaults, the room's RoomDeviceData state, the three media-service drivers, and the digital-audio
service — plus the internal binding topology (as roles, not fixed ids). The controller item and its
proxy subs are NOT here: they are emitted skeletal by authoring.add_controller and Director
regenerates their state/icons on load (proven by Test B / the theater-from-blank pressure test).

Regenerate with the extraction snippet in the 2026-07-13 Mac session notes if the base capture changes.
"""

SCAFFOLD = {
    "room": {
        "name": "Room",
        "type": "8",
        "c4i": "roomdevice.c4i",
        "large_image": "locations_lg\\room.gif",
        "small_image": "locations_sm\\room.gif",
        "state": "<RoomDeviceData><RoomDeviceDataVersion>1.0.0.3</RoomDeviceDataVersion><DefaultAudioVolume>0</DefaultAudioVolume><DefaultVideoVolume>0</DefaultVideoVolume><UseDefaultVolumes>False</UseDefaultVolumes><MuteWhenPaused>False</MuteWhenPaused><UnmuteWhenPowerOn>False</UnmuteWhenPowerOn><MaxBoundWallVideoEP>0</MaxBoundWallVideoEP><IRMask>0</IRMask><RoomHidden>False</RoomHidden><TempHidden>False</TempHidden><EqHidden>True</EqHidden><AnnouncementDisabled>False</AnnouncementDisabled><OrderedMovieList/><OrderedTVList/><OrderedRadioList/><OrderedMusicList/><OrderedLightList/><OrderedLightSceneList/><OrderedCameraList/><OrderedPoolList/><OrderedWatchList><device><deviceid>4294966295</deviceid><order>1</order><hidden>0</hidden></device><device><deviceid>4294966296</deviceid><order>2</order><hidden>0</hidden></device><device><deviceid>4294966308</deviceid><order>3</order><hidden>0</hidden></device></OrderedWatchList><OrderedListenList><device><deviceid>4294966297</deviceid><order>5</order><hidden>0</hidden></device><device><deviceid>4294966298</deviceid><order>3</order><hidden>0</hidden></device><device><deviceid>4294966299</deviceid><order>4</order><hidden>0</hidden></device><device><deviceid>4294966300</deviceid><order>2</order><hidden>0</hidden></device></OrderedListenList><OrderedBlindList/><OrderedContactRelayList/><OrderedComfortList/><OrderedSecurityList/><OrderedSecurityList/><OrderedMediaWallDeviceList/><SpecialDevicesAdded>True</SpecialDevicesAdded></RoomDeviceData>"
    },
    "manage_music": {
        "name": "Manage Music",
        "type": "6",
        "c4i": "AddMusic.c4z",
        "large_image": "c4z:AddMusic/icons/device_lg.png",
        "small_image": "c4z:AddMusic/icons/device_sm.png",
        "state": "<lua_gen_persisting><properties><property><name>Debug Mode</name><value>Off</value></property><property><name>Driver Version</name><value>107</value></property></properties><JSONPersistentData>{\"AuthSettings\":{},\"Search\":{},\"VERSION\":\"107\"}</JSONPersistentData><LicensedDeviceGuid/></lua_gen_persisting>"
    },
    "manage_music_sub": {
        "name": "Manage Music",
        "type": "7",
        "c4i": "media_service.c4i",
        "large_image": "c4z:AddMusic/icons/device_lg.png",
        "small_image": "c4z:AddMusic/icons/device_sm.png",
        "state": ""
    },
    "stations": {
        "name": "Stations",
        "type": "6",
        "c4i": "Stations.c4z",
        "large_image": "c4z:Stations/composer/ico_32_stations.gif",
        "small_image": "c4z:Stations/composer/ico_16_stations.gif",
        "state": "<lua_gen_persisting><properties><property><name>Debug Level</name><value>2 - Warning</value></property><property><name>Debug Mode</name><value>Off</value></property></properties><JSONPersistentData>{}</JSONPersistentData><LicensedDeviceGuid/></lua_gen_persisting>"
    },
    "stations_sub": {
        "name": "Stations",
        "type": "7",
        "c4i": "media_service.c4i",
        "large_image": "c4z:Stations/composer/ico_32_stations.gif",
        "small_image": "c4z:Stations/composer/ico_16_stations.gif",
        "state": ""
    },
    "channels": {
        "name": "Channels",
        "type": "6",
        "c4i": "Channels.c4z",
        "large_image": "c4z:Channels/composer/ico_32_channels.gif",
        "small_image": "c4z:Channels/composer/ico_16_channels.gif",
        "state": "<lua_gen_persisting><properties><property><name>Channel Select goes Home</name><value>Yes</value></property><property><name>Debug Level</name><value>2 - Warning</value></property><property><name>Debug Mode</name><value>Off</value></property></properties><JSONPersistentData>{}</JSONPersistentData><LicensedDeviceGuid/></lua_gen_persisting>"
    },
    "channels_sub": {
        "name": "Channels",
        "type": "7",
        "c4i": "media_service.c4i",
        "large_image": "c4z:Channels/composer/ico_32_channels.gif",
        "small_image": "c4z:Channels/composer/ico_16_channels.gif",
        "state": ""
    },
    "digital_audio": {
        "name": "Digital Media",
        "type": "7",
        "c4i": "control4_digitalaudio.c4i",
        "large_image": "devices_lg/cd.gif",
        "small_image": "devices_sm/cd.gif",
        "state": "<control4_digital_audio><lastserverid>3003</lastserverid><lastmediaid>3501</lastmediaid><ClearPlayList>True</ClearPlayList><ClearPlayListDelay>5</ClearPlayListDelay><AudioLatency3>0</AudioLatency3><PlayPreference>0</PlayPreference><MaxQuality>1</MaxQuality><DistributedAudioExclusionList></DistributedAudioExclusionList><room_queue_settings/></control4_digital_audio>"
    },
    "home": {
        "name": "Home",
        "type": "2",
        "large_image": "locations_lg\\site3.gif",
        "small_image": "locations_sm\\site3.gif"
    },
    "house": {
        "name": "House",
        "type": "3",
        "large_image": "locations_lg\\house.gif",
        "small_image": "locations_sm\\house.gif"
    },
    "floor": {
        "name": "Main",
        "type": "4",
        "large_image": "locations_lg\\main_first_floor.gif",
        "small_image": "locations_sm\\main_first_floor.gif"
    }
}

# provider_role, provider_bindingid, consumer_role, consumer_bindingid, boundclass, name
BINDINGS = [
    ('manage_music_sub', '4001', 'digital_audio', '3001', 'DIGITAL_AUDIO_SERVER', 'Digital Audio'),
    ('digital_audio', '4000', 'manage_music_sub', '3001', 'DIGITAL_AUDIO_CLIENT', 'Digital Audio Client'),
    ('digital_audio', '4000', 'controller_sub', '3000', 'DIGITAL_AUDIO_CLIENT', 'Digital Audio Client'),
    ('stations', '5001', 'stations_sub', '5001', 'MediaService', 'Media Service'),
    ('channels', '5001', 'channels_sub', '5001', 'MediaService', 'Media Service'),
    ('controller', '4100', 'digital_audio', '3002', 'DIGITAL_AUDIO_SERVER', 'Digital Audio'),
    ('controller', '5001', 'controller_sub', '5001', 'CONTROLLER', 'Controller'),
    ('controller', '5002', 'uidevice_sub', '5001', 'UI_DEVICE', 'UIDevice'),
    ('controller_sub', '4100', 'digital_audio', '3000', 'DIGITAL_AUDIO_SERVER', 'Digital Audio'),
    ('controller_sub', '7500', 'room', '6', 'ONSCREEN_SELECTION', 'On-Screen Device'),
    ('manage_music', '5001', 'manage_music_sub', '5001', 'MediaService', 'Media Service'),
]

# Driver files the compound references and that must be bundled in the package's drivers/.
GENERIC_DRIVERS = ['AddMusic.c4z', 'Channels.c4z', 'Stations.c4z',
                   'control4_digitalaudio.c4i', 'media_service.c4i']
# Controller proxy-sub drivers (standard for Control4 controllers).
CONTROLLER_SUB_DRIVERS = ['controller.c4i', 'uidevice.c4i']
