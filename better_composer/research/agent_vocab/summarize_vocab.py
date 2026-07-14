import json, os, glob

BASE_NOISE = {
    "GET_LAST_ACTION", "GET_CAPABILITIES", "GET_COMMAND_INFO", "CAPABILITIES_CHANGED",
    "GREATER_THAN", "GREATER_THAN_OR_EQUAL", "LESS_THAN", "LESS_THAN_OR_EQUAL", "NOT_EQUAL",
    "AUDIO_MEDIA_STORAGE", "AUDIO_SELECTION", "AV_BINDINGS_CHANGED", "BT_AUDIO", "BT_BEGIN",
    "BT_CONTROL", "BT_DEV_NETWORK", "BT_END", "BT_NETWORK", "BT_PROXY", "BT_ROOM_CONTROL",
    "BT_VIDEO", "DIGITAL_5_1", "DIGITAL_7_1", "DIGITAL_AUDIO_CLIENT", "DIGITAL_AUDIO_SERVER",
    "DIGITAL_COAX", "DIGITAL_MEDIA_STORAGE", "DIGITAL_OPTICAL", "ETHERNET_AUDIO", "MP3_AUDIO",
    "MULTI_STEREO", "RF_DIGITAL", "RF_DIRECTV", "RF_DISH", "RF_INTERNET", "RF_SKY", "RF_STAR",
    "S_VIDEO", "VIDEO_AUDIO_SELECTION", "VIDEO_SELECTION",
    "C4_LOG_CONFIG", "SO_PATH", "EXPAND_ONLY", "EXTRACT_AND_EXPAND", "EXTRACT_ONLY",
    "OPENSSL_CONF", "OPENSSL_CONF_INCLUDE", "OPENSSL_ENGINES", "OPENSSL_MODULES",
    "OPENSSL_WIN32_UTF8", "PKEY_ASN1", "PKEY_CRYPTO", "PROXY_NAME", "DIR_ADD", "DIR_LOAD", "LIST_ADD",
    "SOAP_ENV", "AES_128_WRAP", "AES_192_WRAP", "AES_256_WRAP", "ENCRYPTED_PRIVATE_KEY",
    "PRIVATE_KEY", "PUBLIC_KEY", "RSA_PRIVATE_KEY", "RSA_PUBLIC_KEY", "EC_PRIVATE_KEY",
    "X509_CERTIFICATE", "CERTIFICATE_REQUEST", "TRUSTED_CERTIFICATE", "NEW_CERTIFICATE_REQUEST",
    "PKCS7", "PKCS8", "UTF_8", "UTF_16", "CDATA_SECTION",
}

DIR = r"C:\Users\David\OneDrive\Documents\GitHub\Control4\better_composer\research\agent_vocab"
rows = []
for path in sorted(glob.glob(os.path.join(DIR, "*.raw_tokens.json"))):
    d = json.load(open(path, encoding="utf-8"))
    real = [t for t in d["tokens"] if t not in BASE_NOISE]
    rows.append((d["agent"], len(d["tokens"]), len(real), real))

rows.sort(key=lambda r: -r[2])
print(f"{'agent':38}{'total':>7}{'real':>6}")
for agent, total, real_n, real in rows:
    print(f"{agent:38}{total:>7}{real_n:>6}   {', '.join(real[:8])}{'...' if len(real) > 8 else ''}")
