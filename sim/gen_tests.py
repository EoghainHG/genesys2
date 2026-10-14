#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Eoghain Gray

"""
Generate standalone hex test programs for the single-cycle RV32I CPU.
Each test writes 1 to tohost (0x80001000) on pass, (test_num<<1)|1 on fail.

Usage:  python3 sim/gen_tests.py
"""

import os

OUT_DIR = "build/tests"

# ---------------------------------------------------------------------------
# Instruction encoders (all return an unsigned 32-bit int)
# ---------------------------------------------------------------------------

def _r(f7, rs2, rs1, f3, rd, op):
    return ((f7&0x7F)<<25)|((rs2&0x1F)<<20)|((rs1&0x1F)<<15)|((f3&7)<<12)|((rd&0x1F)<<7)|(op&0x7F)

def _i(imm, rs1, f3, rd, op):
    imm &= 0xFFF
    return (imm<<20)|((rs1&0x1F)<<15)|((f3&7)<<12)|((rd&0x1F)<<7)|(op&0x7F)

def _s(imm, rs2, rs1, f3, op):
    imm &= 0xFFF
    return (((imm>>5)&0x7F)<<25)|((rs2&0x1F)<<20)|((rs1&0x1F)<<15)|((f3&7)<<12)|((imm&0x1F)<<7)|(op&0x7F)

def _b(imm, rs2, rs1, f3, op):
    # imm is a signed byte offset (bit 0 forced 0)
    imm &= 0x1FFE
    b12=(imm>>12)&1; b11=(imm>>11)&1; b10_5=(imm>>5)&0x3F; b4_1=(imm>>1)&0xF
    return (b12<<31)|(b10_5<<25)|((rs2&0x1F)<<20)|((rs1&0x1F)<<15)|((f3&7)<<12)|(b4_1<<8)|(b11<<7)|(op&0x7F)

def _u(imm, rd, op):
    return (imm&0xFFFFF000)|((rd&0x1F)<<7)|(op&0x7F)

def _j(imm, rd, op):
    imm &= 0x1FFFFE
    b20=(imm>>20)&1; b10_1=(imm>>1)&0x3FF; b11=(imm>>11)&1; b19_12=(imm>>12)&0xFF
    return (b20<<31)|(b19_12<<12)|(b11<<20)|(b10_1<<21)|((rd&0x1F)<<7)|(op&0x7F)

# Instruction aliases
def NOP():          return _i(0,0,0,0,0x13)
def ADDI(d,s,i):    return _i(i,s,0,d,0x13)
def SLTI(d,s,i):    return _i(i,s,2,d,0x13)
def SLTIU(d,s,i):   return _i(i,s,3,d,0x13)
def XORI(d,s,i):    return _i(i,s,4,d,0x13)
def ORI(d,s,i):     return _i(i,s,6,d,0x13)
def ANDI(d,s,i):    return _i(i,s,7,d,0x13)
def SLLI(d,s,sh):   return _i(sh&0x1F,s,1,d,0x13)
def SRLI(d,s,sh):   return _i(sh&0x1F,s,5,d,0x13)
def SRAI(d,s,sh):   return _i(0x400|(sh&0x1F),s,5,d,0x13)
def ADD(d,s1,s2):   return _r(0,s2,s1,0,d,0x33)
def SUB(d,s1,s2):   return _r(0x20,s2,s1,0,d,0x33)
def SLL(d,s1,s2):   return _r(0,s2,s1,1,d,0x33)
def SLT(d,s1,s2):   return _r(0,s2,s1,2,d,0x33)
def SLTU(d,s1,s2):  return _r(0,s2,s1,3,d,0x33)
def XOR(d,s1,s2):   return _r(0,s2,s1,4,d,0x33)
def SRL(d,s1,s2):   return _r(0,s2,s1,5,d,0x33)
def SRA(d,s1,s2):   return _r(0x20,s2,s1,5,d,0x33)
def OR(d,s1,s2):    return _r(0,s2,s1,6,d,0x33)
def AND(d,s1,s2):   return _r(0,s2,s1,7,d,0x33)
def LW(d,s,i):      return _i(i,s,2,d,0x03)
def LH(d,s,i):      return _i(i,s,1,d,0x03)
def LB(d,s,i):      return _i(i,s,0,d,0x03)
def LHU(d,s,i):     return _i(i,s,5,d,0x03)
def LBU(d,s,i):     return _i(i,s,4,d,0x03)
def SW(base,src,i): return _s(i,src,base,2,0x23)
def SH(base,src,i): return _s(i,src,base,1,0x23)
def SB(base,src,i): return _s(i,src,base,0,0x23)
def LUI(d,i):       return _u(i,d,0x37)
def AUIPC(d,i):     return _u(i,d,0x17)
def JAL(d,i):       return _j(i,d,0x6F)
def JALR(d,s,i):    return _i(i,s,0,d,0x67)
def BEQ(s1,s2,i):   return _b(i,s2,s1,0,0x63)
def BNE(s1,s2,i):   return _b(i,s2,s1,1,0x63)
def BLT(s1,s2,i):   return _b(i,s2,s1,4,0x63)
def BGE(s1,s2,i):   return _b(i,s2,s1,5,0x63)
def BLTU(s1,s2,i):  return _b(i,s2,s1,6,0x63)
def BGEU(s1,s2,i):  return _b(i,s2,s1,7,0x63)

# Registers
x0=0;  ra=1;  sp=2;  gp=3;  tp=4;  t0=5;  t1=6;  t2=7
s0=8;  s1=9;  a0=10; a1=11; a2=12; a3=13; a4=14; a5=15
a6=16; a7=17; s2=18; s3=19; s4=20; s5=21; s6=22; s7=23
s8=24; s9=25; s10=26;s11=27;t3=28; t4=29; t5=30; t6=31

TOHOST = 0x80001000

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def li(rd, val: int) -> list:
    """Load a 32-bit signed/unsigned integer into rd (1 or 2 instructions)."""
    val &= 0xFFFFFFFF
    lower12 = val & 0xFFF
    upper20 = val & 0xFFFFF000
    lower_se = lower12 if lower12 < 0x800 else lower12 - 0x1000  # sign-extend
    if upper20 == 0:
        return [ADDI(rd, x0, lower12)]
    if lower_se < 0:
        adj_upper = (upper20 + 0x1000) & 0xFFFFFFFF
    else:
        adj_upper = upper20
    if lower12 == 0:
        return [LUI(rd, adj_upper)]
    return [LUI(rd, adj_upper), ADDI(rd, rd, lower12)]


def tohost_pass() -> list:
    """Write 1 to tohost then spin."""
    return li(t5, TOHOST) + li(t4, 1) + [SW(t5, t4, 0), JAL(x0, 0)]


def tohost_fail(n: int) -> list:
    """Write (n<<1)|1 to tohost then spin."""
    return li(t5, TOHOST) + li(t4, (n << 1) | 1) + [SW(t5, t4, 0), JAL(x0, 0)]


def check(reg, expected: int, fail_n: int, scratch=t3) -> list:
    """
    Emit: load expected into scratch, then if reg==scratch skip fail else fail.
    Branch offset is computed so BEQ jumps cleanly past the tohost_fail block.
    """
    expected &= 0xFFFFFFFF
    load  = li(scratch, expected)
    tfail = tohost_fail(fail_n)
    # BEQ position inside check(): len(load) instructions before BEQ
    # We want BEQ to jump to the instruction AFTER tfail when equal.
    boffset = (len(tfail) + 1) * 4   # +1 to skip the BEQ itself's fall-through position
    return load + [BEQ(reg, scratch, boffset)] + tfail


def write_hex(name: str, words: list) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"{name}.hex")
    with open(path, "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")
    print(f"  wrote  {path}  ({len(words)} words)")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_alu():
    p = []; n = 1
    p += li(a0, 10) + li(a1, 3)
    p += [ADD(a2, a0, a1)] + check(a2, 13, n); n += 1
    p += [SUB(a2, a0, a1)] + check(a2, 7,  n); n += 1
    p += [AND(a2, a0, a1)] + check(a2, 10 & 3, n); n += 1
    p += [OR(a2,  a0, a1)] + check(a2, 10 | 3, n); n += 1
    p += [XOR(a2, a0, a1)] + check(a2, 10 ^ 3, n); n += 1
    p += [SLL(a2, a0, a1)] + check(a2, 10 << 3, n); n += 1
    p += [SRL(a2, a0, a1)] + check(a2, 10 >> 3, n); n += 1
    p += li(a3, 0xFFFFFF00)  # a3 = -256 (signed)
    p += [SRA(a2, a3, a1)]   # -256 >>> 3 = -32
    p += check(a2, 0xFFFFFFE0, n); n += 1   # -32 = 0xFFFFFFE0
    p += [SLT(a2, a3, a0)]  + check(a2, 1, n); n += 1  # -256 < 10
    p += [SLTU(a2, a0, a3)] + check(a2, 1, n); n += 1  # 10 <u 0xFFFFFF00
    p += tohost_pass()
    write_hex("test_alu", p)


def test_imm():
    p = []; n = 1
    p += li(a0, 42)
    p += [ADDI(a1, a0, 8)]  + check(a1, 50,  n); n += 1
    p += [ANDI(a1, a0, 0xF)]+ check(a1, 42 & 0xF, n); n += 1
    p += [ORI(a1, a0, 5)]   + check(a1, 42 | 5, n); n += 1
    p += [XORI(a1, a0, 15)] + check(a1, 42 ^ 15, n); n += 1
    p += [SLLI(a1, a0, 2)]  + check(a1, 168, n); n += 1
    p += [SRLI(a1, a0, 1)]  + check(a1, 21,  n); n += 1
    p += [SLTI(a1, a0, 100)]+ check(a1, 1,   n); n += 1
    p += [SLTIU(a1, a0,100)]+ check(a1, 1,   n); n += 1
    p += li(a3, 0xFFFFFFFF)   # -1
    p += [SRAI(a1, a3, 3)]  + check(a1, 0xFFFFFFFF, n); n += 1  # -1 >>> 3 = -1
    p += tohost_pass()
    write_hex("test_imm", p)


def test_lui_auipc():
    p = []; n = 1
    # LUI: check full 32-bit result (implicitly verifies lower 12 = 0)
    p += [LUI(a0, 0xDEAD0000)]
    p += check(a0, 0xDEAD0000, n); n += 1
    # LUI: another value
    p += [LUI(a0, 0x12345000)]
    p += check(a0, 0x12345000, n); n += 1
    # AUIPC: PC-relative, result must be >= BASE (0x80000000)
    p += [AUIPC(a0, 0x00001000)]     # a0 = PC + 0x1000
    p += li(a1, 0x80000000)
    tfail = tohost_fail(n); n += 1
    boffset = (len(tfail) + 1) * 4
    p += [BGEU(a0, a1, boffset)] + tfail   # pass if a0 >= BASE
    # AUIPC: two back-to-back AUIPCs differ by exactly 4 bytes
    p += [AUIPC(a0, 0), AUIPC(a1, 0)]     # a1 = a0 + 4
    p += [SUB(a2, a1, a0)]
    p += check(a2, 4, n); n += 1
    p += tohost_pass()
    write_hex("test_lui_auipc", p)


def test_load_store():
    p = []; n = 1
    # Scratch memory area: BASE + 0x800 (safely below tohost at 0x1000)
    p += li(t0, 0x80000800)

    # SW / LW
    p += li(a0, 0x12345678)
    p += [SW(t0, a0, 0), LW(a1, t0, 0)]
    p += check(a1, 0x12345678, n); n += 1

    # SB / LB (signed: -1 byte)
    p += li(a0, 0xFFFFFFFF)           # -1
    p += [SB(t0, a0, 4), LB(a1, t0, 4)]
    p += check(a1, 0xFFFFFFFF, n); n += 1   # sign-extended = -1

    # SB / LBU (unsigned: 0xFF → 255)
    p += [LBU(a1, t0, 4)]
    p += check(a1, 0xFF, n); n += 1

    # SH / LH (signed: -2)
    p += li(a0, 0xFFFFFFFE)           # -2
    p += [SH(t0, a0, 8), LH(a1, t0, 8)]
    p += check(a1, 0xFFFFFFFE, n); n += 1   # sign-extended = -2

    # SH / LHU (unsigned: 0xFFFE → 65534)
    p += [LHU(a1, t0, 8)]
    p += check(a1, 0xFFFE, n); n += 1

    # Byte-lane: SB at offset 1 (addr+1, LSB of that word)
    p += li(a0, 0xAB)
    p += [SB(t0, a0, 1), LBU(a1, t0, 1)]
    p += check(a1, 0xAB, n); n += 1

    p += tohost_pass()
    write_hex("test_load_store", p)


def test_branches():
    p = []; n = 1
    p += li(a0, 5) + li(a1, 5) + li(a2, 10)

    # Each "taken" branch: should branch OVER the tohost_fail block.
    def branch_taken(br_instr_list, fn):
        tfail = tohost_fail(fn)
        boffset = (len(tfail) + 1) * 4
        # Replace last element of br_instr_list with correct offset
        return br_instr_list + tfail

    # Helper: emit `branch_instr boffset` then fail block
    def expect_taken(instr_fn, s1, s2, fn):
        tfail = tohost_fail(fn)
        boffset = (len(tfail) + 1) * 4
        return [instr_fn(s1, s2, boffset)] + tfail

    def expect_not_taken(instr_fn, s1, s2, fn):
        # Branch INCORRECTLY taken → land in fail block
        tfail = tohost_fail(fn)
        # If branch is taken (incorrectly): land at fail[0]
        # If not taken (correctly): fall through to JAL that skips fail
        jal_skip = tohost_fail(fn)  # same size
        skip_offset = (len(jal_skip) + 1) * 4
        return [instr_fn(s1, s2, 8), JAL(x0, skip_offset)] + tfail

    # BEQ a0==a1 (5==5) → should branch
    p += expect_taken(BEQ, a0, a1, n); n += 1
    # BNE a0!=a2 (5!=10) → should branch
    p += expect_taken(BNE, a0, a2, n); n += 1
    # BLT a0<a2 (5<10) → should branch
    p += expect_taken(BLT, a0, a2, n); n += 1
    # BGE a0>=a1 (5>=5) → should branch
    p += expect_taken(BGE, a0, a1, n); n += 1
    # BLTU a0<a2 (unsigned 5<10) → should branch
    p += expect_taken(BLTU, a0, a2, n); n += 1
    # BGEU a0>=a1 (unsigned 5>=5) → should branch
    p += expect_taken(BGEU, a0, a1, n); n += 1

    # BEQ a0==a2 (5==10) → should NOT branch
    p += expect_not_taken(BEQ, a0, a2, n); n += 1
    # BNE a0!=a1 (5!=5) → should NOT branch
    p += expect_not_taken(BNE, a0, a1, n); n += 1
    # BGE a0>=a2 (5>=10) → should NOT branch (signed)
    p += expect_not_taken(BGE, a0, a2, n); n += 1
    # BLT a0<a1 (5<5) → should NOT branch
    p += expect_not_taken(BLT, a0, a1, n); n += 1

    p += tohost_pass()
    write_hex("test_branches", p)


def test_jal_jalr():
    p = []; n = 1

    # -- JAL: jump forward, skipping a fail block --
    tfail = tohost_fail(n); n += 1
    joffset = (len(tfail) + 1) * 4
    p += [JAL(ra, joffset)] + tfail
    # We land here; ra should hold the address of the instruction after JAL.
    # That instruction is tfail[0] which is at BASE + (index_of_jal + 1) * 4.
    # We can't know the exact address without fixing PC, so just check ra != 0.
    # Instead: ensure ra points to somewhere in the correct neighbourhood.
    # JAL was at index 0, so ra = BASE + 4.
    p += li(t0, 0x80000004)  # expected ra
    tfail2 = tohost_fail(n); n += 1
    p += [BEQ(ra, t0, (len(tfail2) + 1) * 4)] + tfail2

    # -- JALR: load target and jump --
    # We'll compute the target address dynamically using AUIPC
    # target = PC of the instruction after the fail block below
    # Structure: AUIPC t1, 0 ; ADDI t1, t1, offset_to_target ; JALR ra, t1, 0 ; fail ; target:
    tfail3 = tohost_fail(n); n += 1
    # offset from AUIPC to target instruction:
    # AUIPC=0, ADDI=1, JALR=2, fail[0..n-1], target = 3 + len(tfail3)
    target_offset = (3 + len(tfail3)) * 4
    p += [
        AUIPC(t1, 0),
        ADDI(t1, t1, target_offset),
        JALR(ra, t1, 0),
    ] + tfail3
    # Landed at target — JALR worked

    p += tohost_pass()
    write_hex("test_jal_jalr", p)


if __name__ == "__main__":
    print(f"Generating tests → {OUT_DIR}/")
    test_alu()
    test_imm()
    test_lui_auipc()
    test_load_store()
    test_branches()
    test_jal_jalr()
    print("Done.")
