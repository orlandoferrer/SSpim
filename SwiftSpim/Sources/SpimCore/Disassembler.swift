import Foundation

/// Machine-word listing for the debugger. Opcode values and operand layouts follow
/// upstream SPIM 9.1.24; see THIRD_PARTY_NOTICES.txt.
public enum SpimDisassembler {
    private struct Encoding {
        let name: String
        let kind: String
        let bits: UInt32
        let mask: UInt32
    }

    private static let encodings: [Encoding] = opcodes.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ")
        guard parts.count == 4,
              let bits = UInt32(parts[2], radix: 16),
              let mask = UInt32(parts[3], radix: 16) else { return nil }
        return Encoding(name: String(parts[0]), kind: String(parts[1]), bits: bits, mask: mask)
    }

    public static func format(_ word: UInt32, at address: UInt32, delayedBranches: Bool = false) -> String {
        func hex(_ value: UInt32) -> String { String(format: "0x%08x", value) }
        if word == 0 { return "nop" }
        guard let encoding = encodings.first(where: { word & $0.mask == $0.bits }) else {
            return ".word \(hex(word))"
        }
        let rs = (word >> 21) & 31
        let rt = (word >> 16) & 31
        let rd = (word >> 11) & 31
        let sa = (word >> 6) & 31
        let imm = Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: word)))
        let branchBase = delayedBranches ? address &+ 4 : address
        let branch = hex(branchBase &+ UInt32(bitPattern: imm &* 4))
        let args: String
        switch encoding.kind {
        case "BC": args = "\(rt >> 2), \(branch)"
        case "B1": args = "$\(rs), \(branch)"
        case "B2": args = "$\(rs), $\(rt), \(branch)"
        case "I1s": args = "$\(rs), \(imm)"
        case "I1t": args = "$\(rt), \(imm)"
        case "I2": args = "$\(rt), $\(rs), \(imm)"
        case "I2a": args = "$\(rt), \(imm)($\(rs))"
        case "R1s": args = "$\(rs)"
        case "R1d": args = "$\(rd)"
        case "R2td": args = "$\(rt), $\(rd)"
        case "R2st": args = "$\(rs), $\(rt)"
        case "R2ds": args = "$\(rd), $\(rs)"
        case "R2sh": args = "$\(rd), $\(rt), \(sa)"
        case "R3": args = "$\(rd), $\(rs), $\(rt)"
        case "R3sh": args = "$\(rd), $\(rt), $\(rs)"
        case "FP_I2a": args = "$f\(rt), \(imm)($\(rs))"
        case "FP_R2ds": args = "$f\(sa), $f\(rd)"
        case "FP_R2ts": args = "$\(rt), $f\(rd)"
        case "FP_CMP": args = sa == 0 ? "$f\(rd), $f\(rt)" : "\(sa >> 2), $f\(rd), $f\(rt)"
        case "FP_R3": args = "$f\(sa), $f\(rd), $f\(rt)"
        case "FP_R4": args = "$f\(sa), $f\(rs), $f\(rd), $f\(rt)"
        case "FP_MOVC": args = "$f\(sa), $f\(rd), \(rt >> 2)"
        case "MOVC": args = "$\(rd), $\(rs), \(rt >> 2)"
        case "J":
            let high = (address &+ 4) & 0xf000_0000
            args = hex(high | ((word & 0x03ff_ffff) << 2))
        default: args = ""
        }
        return args.isEmpty ? encoding.name : "\(encoding.name) \(args)"
    }

    private static let opcodes = """
    deret NOARG 4200001f ffffffff
    ehb NOARG 000000c0 ffffffff
    eret NOARG 42000018 ffffffff
    rfe NOARG 42000010 ffffffff
    sdbbp NOARG 7000003f ffffffff
    tlbp NOARG 42000008 ffffffff
    tlbr NOARG 42000001 ffffffff
    tlbwi NOARG 42000002 ffffffff
    tlbwr NOARG 42000006 ffffffff
    jr R1s 00000008 fc1fffff
    jr.hb R1s 00000408 fc1fffff
    mfhi R1d 00000010 ffff07ff
    mflo R1d 00000012 ffff07ff
    mthi R1s 00000011 fc1fffff
    mtlo R1s 00000013 fc1fffff
    prefx R2st 4600000f fe00ffff
    abs.d FP_R2ds 46200005 ffff003f
    abs.ps FP_R2ds 46600005 ffff003f
    abs.s FP_R2ds 46000005 ffff003f
    ceil.l.d FP_R2ds 4620000a ffff003f
    ceil.l.s FP_R2ds 4600000a ffff003f
    ceil.w.d FP_R2ds 4620000e ffff003f
    ceil.w.s FP_R2ds 4600000e ffff003f
    cfc0 FP_R2ts 40400000 ffe007ff
    cfc1 FP_R2ts 44400000 ffe007ff
    cfc2 FP_R2ts 48400000 ffe007ff
    ctc0 FP_R2ts 40c00000 ffe007ff
    ctc1 FP_R2ts 44c00000 ffe007ff
    ctc2 FP_R2ts 48c00000 ffe007ff
    cvt.d.l FP_R2ds 46b00021 ffff003f
    cvt.d.s FP_R2ds 46000021 ffff003f
    cvt.d.w FP_R2ds 46200021 ffff003f
    cvt.l.d FP_R2ds 46200025 ffff003f
    cvt.l.s FP_R2ds 46000025 ffff003f
    cvt.ps.s FP_R2ds 46000026 ffff003f
    cvt.s.d FP_R2ds 46200020 ffff003f
    cvt.s.l FP_R2ds 46b00020 ffff003f
    cvt.s.pl FP_R2ds 46c00024 ffff003f
    cvt.s.pu FP_R2ds 46c00020 ffff003f
    cvt.s.w FP_R2ds 46800020 ffff003f
    cvt.w.d FP_R2ds 46200024 ffff003f
    cvt.w.s FP_R2ds 46000024 ffff003f
    div R2st 0000001a fc00ffff
    divu R2st 0000001b fc00ffff
    ext FP_R2ds 7c000000 ffff003f
    floor.l.d FP_R2ds 4620000b ffff003f
    floor.l.s FP_R2ds 4600000b ffff003f
    floor.w.d FP_R2ds 4620000f ffff003f
    floor.w.s FP_R2ds 4600000f ffff003f
    ins FP_R2ds 7c000004 ffff003f
    jalr R2ds 00000009 fc1f07ff
    jalr.hb R2ds 00000409 fc1f07ff
    madd R2st 70000000 fc00ffff
    maddu R2st 70000001 fc00ffff
    mfc1 FP_R2ts 44000000 ffe007ff
    mfc2 R2td 48000000 ffe007ff
    mfhc1 FP_R2ts 44600000 ffe007ff
    mfhc2 R2td 48600000 ffe007ff
    mov.d FP_R2ds 46200006 ffff003f
    mov.ps FP_R2ds 46c00006 ffff003f
    mov.s FP_R2ds 46000006 ffff003f
    msub R2st 70000004 fc00ffff
    msubu R2st 70000005 fc00ffff
    mtc1 FP_R2ts 44800000 ffe007ff
    mtc2 R2td 48800000 ffe007ff
    mthc1 FP_R2ts 44e00000 ffe007ff
    mthc2 R2td 48e00000 ffe007ff
    mult R2st 00000018 fc00ffff
    multu R2st 00000019 fc00ffff
    neg.d FP_R2ds 46200007 ffff003f
    neg.ps FP_R2ds 46c00007 ffff003f
    neg.s FP_R2ds 46000007 ffff003f
    rdpgpr R2td 41400000 ffe007ff
    recip.d FP_R2ds 46200015 ffff003f
    recip.s FP_R2ds 46000015 ffff003f
    round.l.d FP_R2ds 46200008 ffff003f
    round.l.s FP_R2ds 46000008 ffff003f
    round.w.d FP_R2ds 4620000c ffff003f
    round.w.s FP_R2ds 4600000c ffff003f
    rsqrt.d FP_R2ds 46200016 ffff003f
    rsqrt.s FP_R2ds 46000016 ffff003f
    seb R2td 7c000420 ffe007ff
    seh R2td 7c000620 ffe007ff
    sqrt.d FP_R2ds 46200004 ffff003f
    sqrt.s FP_R2ds 46000004 ffff003f
    teq R2st 00000034 fc00ffff
    tge R2st 00000030 fc00ffff
    tgeu R2st 00000031 fc00ffff
    tlt R2st 00000032 fc00ffff
    tltu R2st 00000033 fc00ffff
    tne R2st 00000036 fc00ffff
    trunc.l.d FP_R2ds 46200009 ffff003f
    trunc.l.s FP_R2ds 46000009 ffff003f
    trunc.w.d FP_R2ds 4620000d ffff003f
    trunc.w.s FP_R2ds 4600000d ffff003f
    wrpgpr R2td 41c00000 ffe007ff
    wsbh R2td 7c0000a0 ffe007ff
    c.eq.d FP_CMP 46200032 ffe000ff
    c.eq.ps FP_CMP 46600032 ffe000ff
    c.eq.s FP_CMP 46000032 ffe000ff
    c.f.d FP_CMP 46200030 ffe000ff
    c.f.ps FP_CMP 46600030 ffe000ff
    c.f.s FP_CMP 46000030 ffe000ff
    c.le.d FP_CMP 4620003e ffe000ff
    c.le.ps FP_CMP 4660003e ffe000ff
    c.le.s FP_CMP 4600003e ffe000ff
    c.lt.d FP_CMP 4620003c ffe000ff
    c.lt.ps FP_CMP 4660003c ffe000ff
    c.lt.s FP_CMP 4600003c ffe000ff
    c.nge.d FP_CMP 4620003d ffe000ff
    c.nge.ps FP_CMP 4660003d ffe000ff
    c.nge.s FP_CMP 4600003d ffe000ff
    c.ngl.d FP_CMP 4620003b ffe000ff
    c.ngl.ps FP_CMP 4660003b ffe000ff
    c.ngl.s FP_CMP 4600003b ffe000ff
    c.ngle.d FP_CMP 46200039 ffe000ff
    c.ngle.ps FP_CMP 46600039 ffe000ff
    c.ngle.s FP_CMP 46000039 ffe000ff
    c.ngt.d FP_CMP 4620003f ffe000ff
    c.ngt.ps FP_CMP 4660003f ffe000ff
    c.ngt.s FP_CMP 4600003f ffe000ff
    c.ole.d FP_CMP 46200036 ffe000ff
    c.ole.ps FP_CMP 46600036 ffe000ff
    c.ole.s FP_CMP 46000036 ffe000ff
    c.olt.d FP_CMP 46200034 ffe000ff
    c.olt.ps FP_CMP 46600034 ffe000ff
    c.olt.s FP_CMP 46000034 ffe000ff
    c.seq.d FP_CMP 4620003a ffe000ff
    c.seq.ps FP_CMP 4660003a ffe000ff
    c.seq.s FP_CMP 4600003a ffe000ff
    c.sf.d FP_CMP 46200038 ffe000ff
    c.sf.ps FP_CMP 46600038 ffe000ff
    c.sf.s FP_CMP 46000038 ffe000ff
    c.ueq.d FP_CMP 46200033 ffe000ff
    c.ueq.ps FP_CMP 46600033 ffe000ff
    c.ueq.s FP_CMP 46000033 ffe000ff
    c.ule.d FP_CMP 46200037 ffe000ff
    c.ule.ps FP_CMP 46600037 ffe000ff
    c.ule.s FP_CMP 46000037 ffe000ff
    c.ult.d FP_CMP 46200035 ffe000ff
    c.ult.ps FP_CMP 46600035 ffe000ff
    c.ult.s FP_CMP 46000035 ffe000ff
    c.un.d FP_CMP 46200031 ffe000ff
    c.un.ps FP_CMP 46600031 ffe000ff
    c.un.s FP_CMP 46000031 ffe000ff
    mfc0 R2td 40000000 ffe007f8
    movf MOVC 00000001 fc0307ff
    movf.d FP_MOVC 46200011 ffe3003f
    movf.ps FP_MOVC 46c00011 ffe3003f
    movf.s FP_MOVC 46000011 ffe3003f
    movn.d FP_MOVC 46200013 ffe3003f
    movn.ps FP_MOVC 46c00013 ffe3003f
    movn.s FP_MOVC 46000013 ffe3003f
    movt MOVC 00010001 fc0307ff
    movt.d FP_MOVC 46210011 ffe3003f
    movt.ps FP_MOVC 46c10011 ffe3003f
    movt.s FP_MOVC 46010011 ffe3003f
    movz.d FP_MOVC 46200012 ffe3003f
    movz.ps FP_MOVC 46c00012 ffe3003f
    movz.s FP_MOVC 46000012 ffe3003f
    mtc0 R2td 40800000 ffe007f8
    ssnop R2sh 00000040 ffe0007f
    add R3 00000020 fc0007ff
    add.d FP_R3 46200000 ffe0003f
    add.ps FP_R3 46600000 ffe0003f
    add.s FP_R3 46000000 ffe0003f
    addu R3 00000021 fc0007ff
    and R3 00000024 fc0007ff
    clo R3 70000021 fc0007ff
    clz R3 70000020 fc0007ff
    div.d FP_R3 46200003 ffe0003f
    div.s FP_R3 46000003 ffe0003f
    ldxc1 FP_R3 4c000001 ffe0003f
    luxc1 FP_R3 4c000005 ffe0003f
    lwxc1 FP_R3 4c000000 ffe0003f
    movn R3 0000000b fc0007ff
    movz R3 0000000a fc0007ff
    mul R3 70000002 fc0007ff
    mul.d FP_R3 46200002 ffe0003f
    mul.ps FP_R3 46c00002 ffe0003f
    mul.s FP_R3 46000002 ffe0003f
    nor R3 00000027 fc0007ff
    or R3 00000025 fc0007ff
    pll.ps FP_R3 46c0002c ffe0003f
    plu.ps FP_R3 46c0002d ffe0003f
    pul.ps FP_R3 46c0002e ffe0003f
    puu.ps FP_R3 46c0002f ffe0003f
    rdhwr R3 7c00003b fc0007ff
    rotr R2sh 00200002 ffe0003f
    rotrv R2sh 00200003 ffe0003f
    sdxc1 FP_R3 46000009 ffe0003f
    sll R2sh 00000000 ffe0003f
    sllv R3sh 00000004 fc0007ff
    slt R3 0000002a fc0007ff
    sltu R3 0000002b fc0007ff
    sra R2sh 00000003 ffe0003f
    srav R3sh 00000007 fc0007ff
    srl R2sh 00000002 ffe0003f
    srlv R3sh 00000006 fc0007ff
    sub R3 00000022 fc0007ff
    sub.d FP_R3 46200001 ffe0003f
    sub.ps FP_R3 46600001 ffe0003f
    sub.s FP_R3 46000001 ffe0003f
    subu R3 00000023 fc0007ff
    suxc1 FP_R3 4600000d ffe0003f
    swxc1 FP_R3 46000008 ffe0003f
    xor R3 00000026 fc0007ff
    ei I1t 41606020 ffe06020
    bc1f BC 45000000 ffe30000
    bc1fl BC 45020000 ffe30000
    bc1t BC 45010000 ffe30000
    bc1tl BC 45030000 ffe30000
    bc2f BC 49000000 ffe30000
    bc2fl BC 49020000 ffe30000
    bc2t BC 49010000 ffe30000
    bc2tl BC 49030000 ffe30000
    di I1t 41606000 ffe06000
    alnv.ps FP_R4 4c00001e fc00003f
    break NOARG 0000000d fc00003f
    madd.d FP_R4 4c000001 fc00003f
    madd.ps FP_R4 4c000006 fc00003f
    madd.s FP_R4 4c000000 fc00003f
    msub.d FP_R4 4c000021 fc00003f
    msub.ps FP_R4 4c000026 fc00003f
    msub.s FP_R4 4c000020 fc00003f
    nmadd.d FP_R4 4c000031 fc00003f
    nmadd.ps FP_R4 4c000036 fc00003f
    nmadd.s FP_R4 4c000030 fc00003f
    nmsub.d FP_R4 4c000039 fc00003f
    nmsub.ps FP_R4 4c00003e fc00003f
    nmsub.s FP_R4 4c000038 fc00003f
    sync NOARG 0000000f fc00003f
    syscall NOARG 0000000c fc00003f
    bgez B1 04010000 fc1f0000
    bgezal B1 04110000 fc1f0000
    bgezall B1 04130000 fc1f0000
    bgezl B1 04030000 fc1f0000
    bgtz B1 1c000000 fc1f0000
    bgtzl B1 5c000000 fc1f0000
    blez B1 18000000 fc1f0000
    blezl B1 58000000 fc1f0000
    bltz B1 04000000 fc1f0000
    bltzal B1 04100000 fc1f0000
    bltzall B1 04120000 fc1f0000
    bltzl B1 04020000 fc1f0000
    lui I1t 3c000000 ffe00000
    teqi I1s 040c0000 fc1f0000
    tgei I1s 04080000 fc1f0000
    tgeiu I1s 04090000 fc1f0000
    tlti I1s 040a0000 fc1f0000
    tltiu I1s 040b0000 fc1f0000
    tnei I1s 040e0000 fc1f0000
    synci I2 04140000 fc140000
    cop2 J 4a000000 fe000000
    addi I2 20000000 fc000000
    addiu I2 24000000 fc000000
    andi I2 30000000 fc000000
    beq B2 10000000 fc000000
    beql B2 50000000 fc000000
    bne B2 14000000 fc000000
    bnel B2 54000000 fc000000
    cache I2 bc000000 fc000000
    j J 08000000 fc000000
    jal J 0c000000 fc000000
    lb I2a 80000000 fc000000
    lbu I2a 90000000 fc000000
    ldc1 FP_I2a d4000000 fc000000
    ldc2 I2a d8000000 fc000000
    lh I2a 84000000 fc000000
    lhu I2a 94000000 fc000000
    ll I2a c0000000 fc000000
    lw I2a 8c000000 fc000000
    lwc1 FP_I2a c4000000 fc000000
    lwc2 I2a c8000000 fc000000
    lwl I2a 88000000 fc000000
    lwr I2a 98000000 fc000000
    ori I2 34000000 fc000000
    pref I2 cc000000 fc000000
    sb I2a a0000000 fc000000
    sc I2a e0000000 fc000000
    sdc1 FP_I2a f4000000 fc000000
    sdc2 I2a f8000000 fc000000
    sh I2a a4000000 fc000000
    slti I2 28000000 fc000000
    sltiu I2 2c000000 fc000000
    sw I2a ac000000 fc000000
    swc1 FP_I2a e4000000 fc000000
    swc2 I2a e8000000 fc000000
    swl I2a a8000000 fc000000
    swr I2a b8000000 fc000000
    xori I2 38000000 fc000000
    """
}
