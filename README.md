# Problem 074 - RISC-V CPU (rv32ic)

**ACMOJ Problem ID**: 2532

## Introduction

### Background

This is an extended version of the RISC-V CPU project. In addition to the base RV32I instruction set, this problem requires support for the **RV32C compressed instruction extension**. The C extension adds 16-bit compressed instructions that map to common RV32I instructions, reducing code size while maintaining performance.

This is a hardware design project from the ACM Class at Shanghai Jiao Tong University, based on the [RISCV-CPU project](https://github.com/ACMClassCourses/RISCV-CPU).

## Assignment Description

### Grade Composition

| Grading Component | Percentage |
| :--: | :--: |
| Pass **2532. CPU 2024 (rv32ic)** simulation tests | 75% |
| FPGA tests | 10% |
| Code Review | 15% |

## Assignment Requirements

### Project Overview

You must implement a **speculative, out-of-order execution** RISC-V CPU supporting both the **RV32I** base instruction set and the **RV32C** compressed instruction extension using Verilog. The CPU architecture should follow the Tomasulo algorithm.

### RV32I Required Instructions (37 total)

`LUI`, `AUIPC`, `JAL`, `JALR`, `BEQ`, `BNE`, `BLT`, `BGE`, `BLTU`, `BGEU`, `LB`, `LH`, `LW`, `LBU`, `LHU`, `SB`, `SH`, `SW`, `ADDI`, `SLLI`, `SLTI`, `SLTIU`, `XORI`, `SRLI`, `SRAI`, `ORI`, `ANDI`, `ADD`, `SUB`, `SLL`, `SLT`, `SLTU`, `XOR`, `SRL`, `SRA`, `OR`, `AND`

### RV32C Compressed Extension

The C extension provides 16-bit encodings for frequently used instructions. Key compressed instructions include:

- **Loads/Stores**: `C.LW`, `C.SW`, `C.LWSP`, `C.SWSP`
- **Arithmetic**: `C.ADDI`, `C.ADD`, `C.SUB`, `C.AND`, `C.OR`, `C.XOR`, `C.ANDI`
- **Shifts**: `C.SLLI`, `C.SRLI`, `C.SRAI`
- **Branches**: `C.BEQZ`, `C.BNEZ`
- **Jumps**: `C.J`, `C.JAL`, `C.JR`, `C.JALR`
- **Misc**: `C.LI`, `C.LUI`, `C.MV`, `C.NOP`, `C.ADDI16SP`, `C.ADDI4SPN`

The instruction fetch unit must handle variable-length instructions (16-bit and 32-bit mixed) and align them correctly.

### Repository Structure

```
RISCV-CPU/
├── riscv/
│   ├── fpga/           # FPGA interface
│   ├── sim/            # Simulation testbench
│   ├── src/            # HDL source code
│   │   ├── common/     # Provided UART and RAM modules
│   │   └── cpu.v       # CPU core (main file to implement)
│   ├── sys/            # Compilation support files
│   ├── testcase/       # Test programs
│   │   ├── fpga/       # Full test suite
│   │   └── sim/        # Simulation test subset
│   ├── testspace/      # Build output
│   └── Makefile        # Build and test scripts
└── serial/             # Third-party FPGA serial library
```

### Technical Details

- Memory size: 128KB (addresses below 0x20000)
- Special I/O: reading/writing at 0x30000 and 0x30004 for UART communication
- Execution starts from address 0x0000000
- Register file: 32 general-purpose registers (x0-x31)
- Must handle mixed 16-bit and 32-bit instruction streams
- The CPU must handle `rdy_in` (ready) and `rst_in` (reset) signals correctly

## Per-Testcase Resource Limits

- **Simulation Time Limit**: varies per test case
- **Language**: Verilog (submitted via git repository)

## Submission Requirements

### OJ Git Repository Submission

Submit a git repository URL containing your Verilog implementation. The OJ will clone your repository and run simulation tests against the provided testbench.

The repository must follow the structure provided in the [RISCV-CPU template](https://github.com/ACMClassCourses/RISCV-CPU), with your implementation primarily in `riscv/src/cpu.v` and additional module files.

### Evaluation Notes

- The evaluation system runs iVerilog simulation against comprehensive test programs (compiled with `-march=rv32ic`)
- Test programs include both 32-bit and compressed 16-bit instructions
- Output must exactly match expected results
- Simulation timeout indicates the CPU is too slow or has infinite loops

### Academic Integrity

If any violations are found during evaluation or code review, your final score may be significantly reduced or become **0 points**.
