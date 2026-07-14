import struct, sys

def get_exports(path):
    data = open(path, 'rb').read()
    pe_off = struct.unpack('<I', data[0x3c:0x40])[0]
    magic = struct.unpack('<H', data[pe_off+24:pe_off+26])[0]
    is_pe32plus = (magic == 0x20b)
    dd_off = pe_off + 24 + (112 if is_pe32plus else 96)
    export_rva, export_size = struct.unpack('<II', data[dd_off:dd_off+8])
    if export_rva == 0:
        return []

    # parse section headers to map RVA -> file offset
    num_sections = struct.unpack('<H', data[pe_off+6:pe_off+8])[0]
    opt_header_size = struct.unpack('<H', data[pe_off+20:pe_off+22])[0]
    section_table_off = pe_off + 24 + opt_header_size
    sections = []
    for i in range(num_sections):
        off = section_table_off + i*40
        name = data[off:off+8].rstrip(b'\x00').decode('latin-1')
        vsize, vaddr, rawsize, rawptr = struct.unpack('<IIII', data[off+8:off+24])
        sections.append((vaddr, vsize, rawptr, rawsize, name))

    def rva_to_off(rva):
        for vaddr, vsize, rawptr, rawsize, name in sections:
            if vaddr <= rva < vaddr + max(vsize, rawsize):
                return rawptr + (rva - vaddr)
        return None

    exp_off = rva_to_off(export_rva)
    if exp_off is None:
        return []
    # IMAGE_EXPORT_DIRECTORY layout
    (characteristics, timestamp, majorv, minorv, name_rva, base,
     num_funcs, num_names, func_rva, name_rva_tbl, ordinal_rva) = struct.unpack('<IIHHIIIIIII', data[exp_off:exp_off+40])

    names_off = rva_to_off(name_rva_tbl)
    results = []
    for i in range(num_names):
        nptr = struct.unpack('<I', data[names_off + i*4: names_off + i*4 + 4])[0]
        noff = rva_to_off(nptr)
        end = data.find(b'\x00', noff)
        name = data[noff:end].decode('latin-1', errors='replace')
        results.append(name)
    return results

if __name__ == '__main__':
    for path in sys.argv[1:]:
        print(f"=== {path} ===")
        try:
            exports = get_exports(path)
            for e in exports:
                print(" ", e)
            if not exports:
                print("  (no exports)")
        except Exception as ex:
            print("  ERROR:", ex)
