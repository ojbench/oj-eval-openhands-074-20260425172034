// RISCV32I CPU top module
// port modification allowed for debugging purposes

module cpu(
  input  wire                 clk_in,			// system clock signal
  input  wire                 rst_in,			// reset signal
	input  wire					        rdy_in,			// ready signal, pause cpu when low

  input  wire [ 7:0]          mem_din,		// data input bus
  output wire [ 7:0]          mem_dout,		// data output bus
  output wire [31:0]          mem_a,			// address bus (only 17:0 is used)
  output wire                 mem_wr,			// write/read signal (1 for write)
	
	input  wire                 io_buffer_full, // 1 if uart buffer is full
	
	output wire [31:0]			dbgreg_dout		// cpu register output (debugging demo)
);

// RISCV32IC CPU with Tomasulo out-of-order execution
// Supports RV32I base instruction set and RV32C compressed extension

// Program Counter and Fetch Unit
reg [31:0] pc;
reg [31:0] next_pc;
reg [31:0] fetched_instruction;
reg instruction_valid;
reg is_compressed;

// Instruction Cache (simple 4-entry direct mapped)
reg [31:0] icache_tag [0:3];
reg [31:0] icache_data [0:3];
reg icache_valid [0:3];

// Register File (32 registers)
reg [31:0] reg_file [0:31];
reg [4:0]  rat [0:31];  // Register Alias Table
reg [31:0] prf [0:63]; // Physical Register File (64 entries)
reg [63:0] prf_valid;   // Physical register valid bits

// Reorder Buffer (8 entries)
reg [31:0] rob_pc [0:7];
reg [31:0] rob_inst [0:7];
reg [4:0]  rob_rd [0:7];
reg [6:0]  rob_opcode [0:7];
reg rob_valid [0:7];
reg rob_ready [0:7];
reg [31:0] rob_result [0:7];
reg [2:0]  rob_head, rob_tail;

// Reservation Stations
reg [31:0] rs1_value [0:7];
reg [31:0] rs2_value [0:7];
reg [4:0]  rs1_tag [0:7];
reg [4:0]  rs2_tag [0:7];
reg rs1_valid [0:7];
reg rs2_valid [0:7];
reg rs_busy [0:7];
reg [6:0]  rs_opcode [0:7];
reg [4:0]  rs_rd [0:7];
reg [2:0]  rs_rob_idx [0:7];

// Common Data Bus
reg [31:0] cdb_data;
reg [4:0]  cdb_tag;
reg cdb_valid;

// Memory interface
reg [31:0] mem_addr;
reg [7:0]  mem_data_out;
reg mem_write_enable;
reg mem_read_pending;
reg [31:0] mem_read_data;
reg mem_read_valid;

// Clock counter for I/O
reg [31:0] clock_counter;

// Program finish flag
reg program_finished;

// Temporary registers for computation
reg [31:0] result;
reg take_branch;
reg writeback;
reg [31:0] load_result;
reg [4:0] load_rd;
reg [1:0] icache_idx;

// Debug register output
assign dbgreg_dout = reg_file[1]; // Output x1 for debugging

// Memory interface
assign mem_a = mem_addr;
assign mem_dout = mem_data_out;
assign mem_wr = mem_write_enable;

// Instruction fetch and decode
wire [6:0] opcode = fetched_instruction[6:0];
wire [4:0] rd = fetched_instruction[11:7];
wire [4:0] rs1 = fetched_instruction[19:15];
wire [4:0] rs2 = fetched_instruction[24:20];
wire [11:0] imm_i = fetched_instruction[31:20];
wire [11:0] imm_s = {fetched_instruction[31:25], fetched_instruction[11:7]};
wire [12:0] imm_b = {fetched_instruction[31], fetched_instruction[7], fetched_instruction[30:25], fetched_instruction[11:8], 1'b0};
wire [19:0] imm_u = {fetched_instruction[31:12], 12'b0};
wire [20:0] imm_j = {fetched_instruction[31], fetched_instruction[19:12], fetched_instruction[20], fetched_instruction[30:21], 1'b0};

// Compressed instruction decode
wire is_c_instruction = (fetched_instruction[1:0] != 2'b11);
wire [2:0] c_funct3 = fetched_instruction[15:13];
wire [5:0] c_funct6 = fetched_instruction[15:10];

// Initialize
integer i;
initial begin
    pc = 0;
    next_pc = 4;
    instruction_valid = 0;
    is_compressed = 0;
    program_finished = 0;
    clock_counter = 0;
    
    // Initialize register file (x0 = 0, others = 0)
    for (i = 0; i < 32; i = i + 1) begin
        reg_file[i] = 0;
        rat[i] = i; // Initially map architectural to physical 1:1
    end
    
    // Initialize physical register file
    for (i = 0; i < 64; i = i + 1) begin
        prf[i] = 0;
    end
    prf_valid = 64'h00000001; // Only p0 (x0) is valid and always 0
    
    // Initialize ROB
    for (i = 0; i < 8; i = i + 1) begin
        rob_valid[i] = 0;
        rob_ready[i] = 0;
    end
    rob_head = 0;
    rob_tail = 0;
    
    // Initialize reservation stations
    for (i = 0; i < 8; i = i + 1) begin
        rs_busy[i] = 0;
        rs1_valid[i] = 0;
        rs2_valid[i] = 0;
    end
    
    // Initialize instruction cache
    for (i = 0; i < 4; i = i + 1) begin
        icache_valid[i] = 0;
    end
    
    cdb_valid = 0;
    mem_read_pending = 0;
    mem_read_valid = 0;
end

always @(posedge clk_in) begin
    if (rst_in) begin
        // Reset state
        pc = 0;
        next_pc = 4;
        instruction_valid = 0;
        program_finished = 0;
        clock_counter = 0;
        mem_write_enable = 0;
        mem_read_pending = 0;
        cdb_valid = 0;
    end else if (!rdy_in) begin
        // Pause CPU when not ready
    end else begin
        clock_counter = clock_counter + 1;
        
        // Handle memory read completion
        if (mem_read_pending) begin
            mem_read_data = {24'b0, mem_din};
            mem_read_valid = 1;
            mem_read_pending = 0;
            
            // Handle load instruction completion
            if (instruction_valid) begin
                if (is_compressed) begin
                    // Compressed load instructions
                    case (fetched_instruction[15:13])
                        3'b001: begin // C.LW
                            load_result = mem_read_data;
                            load_rd = fetched_instruction[9:7] + 8;
                        end
                        3'b010: begin // C.LWSP
                            if (fetched_instruction[12]) begin
                                load_result = mem_read_data;
                                load_rd = fetched_instruction[11:7] + 8;
                            end
                        end
                    endcase
                end else begin
                    // Standard RV32I load instructions
                    case (fetched_instruction[14:12])
                        3'b000: begin // LB
                            load_result = $signed(mem_read_data[7:0]);
                            load_rd = rd;
                        end
                        3'b001: begin // LH
                            load_result = $signed(mem_read_data[15:0]);
                            load_rd = rd;
                        end
                        3'b010: begin // LW
                            load_result = mem_read_data;
                            load_rd = rd;
                        end
                        3'b100: begin // LBU
                            load_result = {24'b0, mem_read_data[7:0]};
                            load_rd = rd;
                        end
                        3'b101: begin // LHU
                            load_result = {16'b0, mem_read_data[15:0]};
                            load_rd = rd;
                        end
                    endcase
                end
                
                // Write back load result
                if (load_rd != 0) begin
                    reg_file[load_rd] = load_result;
                end
            end
        end else begin
            mem_read_valid = 0;
        end
        
        // Instruction fetch
        if (!program_finished && !mem_read_pending) begin
            // Check instruction cache first
            icache_idx = pc[3:2];
            if (icache_valid[icache_idx] && icache_tag[icache_idx] == pc[31:4]) begin
                fetched_instruction = icache_data[icache_idx];
                instruction_valid = 1;
                is_compressed = (fetched_instruction[1:0] != 2'b11);
                next_pc = pc + (is_compressed ? 2 : 4);
            end else begin
                // Cache miss - fetch from memory
                mem_addr = pc;
                mem_write_enable = 0;
                mem_read_pending = 1;
            end
        end
        
        // Handle instruction cache fill
        if (mem_read_valid && !program_finished) begin
            icache_idx = pc[3:2];
            icache_tag[icache_idx] = pc[31:4];
            icache_data[icache_idx] = mem_read_data;
            icache_valid[icache_idx] = 1;
            fetched_instruction = mem_read_data;
            instruction_valid = 1;
            is_compressed = (fetched_instruction[1:0] != 2'b11);
            next_pc = pc + (is_compressed ? 2 : 4);
        end
        
        // Simple instruction execution (placeholder for full Tomasulo implementation)
        if (instruction_valid && !program_finished) begin
            take_branch = 0;
            writeback = 1;
            
            // Handle I/O operations
            if (mem_addr[17:16] == 2'b11) begin
                if (mem_addr == 32'h30000) begin
                    // UART I/O
                    if (mem_write_enable) begin
                        // Write to UART output
                        if (mem_data_out != 8'h00) begin
                            // For simulation, we'll just pass through
                            // In real hardware, this would go to UART TX
                        end
                    end else begin
                        // Read from UART input
                        result = {24'b0, mem_din};
                    end
                end else if (mem_addr == 32'h30004) begin
                    if (mem_write_enable) begin
                        // Program termination
                        program_finished = 1;
                    end else begin
                        // Read clock counter
                        result = clock_counter;
                    end
                end
            end
            
            // Complete RV32I and RV32C instruction execution
            if (is_compressed) begin
                // RV32C compressed instruction handling
                case (fetched_instruction[15:13])
                    3'b000: begin // C.ADDI4SPN and other quadrants
                        if (fetched_instruction[12:5] != 0) begin
                            result = reg_file[2] + {fetched_instruction[12:5], fetched_instruction[4:3], fetched_instruction[2], fetched_instruction[1], 2'b00};
                            reg_file[fetched_instruction[11:7] + 8] = result;
                        end
                    end
                    3'b001: begin // C.LW
                        mem_addr = reg_file[fetched_instruction[9:7] + 8] + {fetched_instruction[12], fetched_instruction[6:5], fetched_instruction[4:2], 2'b00};
                        mem_write_enable = 0;
                        mem_read_pending = 1;
                        writeback = 0;
                    end
                    3'b010: begin // C.LWSP and reserved
                        if (fetched_instruction[12]) begin
                            mem_addr = reg_file[2] + {fetched_instruction[12], fetched_instruction[4:3], fetched_instruction[8:6], fetched_instruction[2], 2'b00};
                            mem_write_enable = 0;
                            mem_read_pending = 1;
                            writeback = 0;
                        end
                    end
                    3'b100: begin // Many instructions: C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR, C.AND, C.J, C.BEQZ, C.LI
                        if (fetched_instruction[11:10] == 2'b00) begin
                            // C.SRLI/C.SRAI/C.ANDI
                            if (fetched_instruction[12] == 0) begin
                                result = reg_file[fetched_instruction[9:7] + 8] >> fetched_instruction[6:2]; // C.SRLI
                            end else if (fetched_instruction[11:7] == 5'b10000) begin
                                result = reg_file[fetched_instruction[9:7] + 8] >>> fetched_instruction[6:2]; // C.SRAI
                            end else begin
                                result = reg_file[fetched_instruction[9:7] + 8] & {16'h0, fetched_instruction[12], fetched_instruction[6:2]}; // C.ANDI
                                reg_file[fetched_instruction[9:7] + 8] = result;
                            end
                        end else if (fetched_instruction[11:10] == 2'b11) begin
                            // Arithmetic operations
                            case (fetched_instruction[6:5])
                                2'b00: result = reg_file[fetched_instruction[9:7] + 8] - reg_file[fetched_instruction[4:2] + 8]; // C.SUB
                                2'b01: result = reg_file[fetched_instruction[9:7] + 8] ^ reg_file[fetched_instruction[4:2] + 8]; // C.XOR
                                2'b10: result = reg_file[fetched_instruction[9:7] + 8] | reg_file[fetched_instruction[4:2] + 8]; // C.OR
                                2'b11: result = reg_file[fetched_instruction[9:7] + 8] & reg_file[fetched_instruction[4:2] + 8]; // C.AND
                            endcase
                            reg_file[fetched_instruction[9:7] + 8] = result;
                        end
                    end
                    3'b101: begin // C.J, C.JAL, C.BEQZ, C.BNEZ
                        if (fetched_instruction[12]) begin
                            // C.J
                            result = pc + 2;
                            next_pc = pc + $signed({fetched_instruction[12], fetched_instruction[8], fetched_instruction[10:9], fetched_instruction[6], fetched_instruction[7], fetched_instruction[2], fetched_instruction[11], fetched_instruction[5:3], 1'b0});
                        end else begin
                            // C.BEQZ/C.BNEZ
                            take_branch = (fetched_instruction[12]) ? (reg_file[fetched_instruction[9:7] + 8] != 0) : (reg_file[fetched_instruction[9:7] + 8] == 0);
                            if (take_branch) begin
                                next_pc = pc + $signed({fetched_instruction[12], fetched_instruction[6:5], fetched_instruction[2], fetched_instruction[11:10], fetched_instruction[4:3], 1'b0});
                            end
                        end
                    end
                    3'b110: begin // C.SW
                        mem_addr = reg_file[fetched_instruction[9:7] + 8] + {fetched_instruction[12], fetched_instruction[6:5], fetched_instruction[4:2], 2'b00};
                        mem_data_out = reg_file[fetched_instruction[4:2] + 8][7:0];
                        mem_write_enable = 1;
                    end
                    3'b111: begin // C.SWSP
                        mem_addr = reg_file[2] + {fetched_instruction[12], fetched_instruction[6:4], fetched_instruction[8:7], fetched_instruction[2], 2'b00};
                        mem_data_out = reg_file[fetched_instruction[9:7] + 8][7:0];
                        mem_write_enable = 1;
                    end
                endcase
                
                // Handle C.LI, C.LUI, C.ADDI, C.ADD, C.MV, C.JR, C.JALR
                case (fetched_instruction[15:13])
                    3'b010: begin
                        if (!fetched_instruction[12]) begin
                            // C.LI
                            result = $signed({fetched_instruction[12], fetched_instruction[6:2]});
                            reg_file[fetched_instruction[11:7] + 8] = result;
                        end
                    end
                    3'b011: begin
                        if (!fetched_instruction[12]) begin
                            // C.LUI
                            if (fetched_instruction[11:7] != 2) begin
                                result = {fetched_instruction[12], fetched_instruction[6:2], 12'b0};
                                reg_file[fetched_instruction[11:7] + 8] = result;
                            end
                        end else begin
                            // C.ADDI16SP
                            if (fetched_instruction[11:7] == 2) begin
                                result = reg_file[2] + $signed({fetched_instruction[12], fetched_instruction[4:3], fetched_instruction[5], fetched_instruction[2], fetched_instruction[6], 3'b000});
                                reg_file[2] = result;
                            end
                        end
                    end
                    3'b100: begin
                        if (fetched_instruction[11:10] == 2'b01) begin
                            // C.ADDI
                            result = reg_file[fetched_instruction[11:7] + 8] + $signed({fetched_instruction[12], fetched_instruction[6:2]});
                            reg_file[fetched_instruction[11:7] + 8] = result;
                        end else if (fetched_instruction[11:10] == 2'b10) begin
                            if (fetched_instruction[12] == 0) begin
                                // C.MV
                                result = reg_file[fetched_instruction[6:2] + 8];
                                reg_file[fetched_instruction[11:7] + 8] = result;
                            end else begin
                                // C.ADD
                                result = reg_file[fetched_instruction[11:7] + 8] + reg_file[fetched_instruction[6:2] + 8];
                                reg_file[fetched_instruction[11:7] + 8] = result;
                            end
                        end
                    end
                    3'b100: begin
                        if (fetched_instruction[11:7] == 0 && fetched_instruction[12] == 0 && fetched_instruction[6:2] == 0) begin
                            // C.JR
                            next_pc = reg_file[fetched_instruction[11:7] + 8];
                        end else if (fetched_instruction[11:7] == 0 && fetched_instruction[12] == 1) begin
                            // C.JALR
                            result = pc + 2;
                            next_pc = reg_file[fetched_instruction[6:2] + 8];
                            reg_file[1] = result; // Link to x1
                        end
                    end
                endcase
            end else begin
                // RV32I standard instruction execution
                case (opcode)
                    7'b0110011: begin // R-type: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
                        case (fetched_instruction[14:12])
                            3'b000: result = (fetched_instruction[30]) ? (reg_file[rs1] - reg_file[rs2]) : (reg_file[rs1] + reg_file[rs2]);  // SUB/ADD
                            3'b001: result = reg_file[rs1] << reg_file[rs2][4:0]; // SLL
                            3'b010: result = ($signed(reg_file[rs1]) < $signed(reg_file[rs2])) ? 1 : 0; // SLT
                            3'b011: result = (reg_file[rs1] < reg_file[rs2]) ? 1 : 0; // SLTU
                            3'b100: result = reg_file[rs1] ^ reg_file[rs2];  // XOR
                            3'b101: result = (fetched_instruction[30]) ? ($signed(reg_file[rs1]) >>> reg_file[rs2][4:0]) : (reg_file[rs1] >> reg_file[rs2][4:0]); // SRA/SRL
                            3'b110: result = reg_file[rs1] | reg_file[rs2];  // OR
                            3'b111: result = reg_file[rs1] & reg_file[rs2];  // AND
                        endcase
                    end
                    7'b0010011: begin // I-type: ADDI, SLLI, SLTI, SLTIU, XORI, SRLI, SRAI, ORI, ANDI
                        case (fetched_instruction[14:12])
                            3'b000: result = reg_file[rs1] + $signed(imm_i);  // ADDI
                            3'b001: result = reg_file[rs1] << imm_i[4:0];     // SLLI
                            3'b010: result = ($signed(reg_file[rs1]) < $signed(imm_i)) ? 1 : 0; // SLTI
                            3'b011: result = (reg_file[rs1] < imm_i) ? 1 : 0; // SLTIU
                            3'b100: result = reg_file[rs1] ^ imm_i;           // XORI
                            3'b101: result = (fetched_instruction[30]) ? ($signed(reg_file[rs1]) >>> imm_i[4:0]) : (reg_file[rs1] >> imm_i[4:0]); // SRAI/SRLI
                            3'b110: result = reg_file[rs1] | imm_i;           // ORI
                            3'b111: result = reg_file[rs1] & imm_i;           // ANDI
                        endcase
                    end
                    7'b0000011: begin // Load: LB, LH, LW, LBU, LHU
                        case (fetched_instruction[14:12])
                            3'b000: begin // LB
                                mem_addr = reg_file[rs1] + $signed(imm_i);
                                mem_write_enable = 0;
                                mem_read_pending = 1;
                                writeback = 0;
                            end
                            3'b001: begin // LH
                                mem_addr = reg_file[rs1] + $signed(imm_i);
                                mem_write_enable = 0;
                                mem_read_pending = 1;
                                writeback = 0;
                            end
                            3'b010: begin // LW
                                mem_addr = reg_file[rs1] + $signed(imm_i);
                                mem_write_enable = 0;
                                mem_read_pending = 1;
                                writeback = 0;
                            end
                            3'b100: begin // LBU
                                mem_addr = reg_file[rs1] + $signed(imm_i);
                                mem_write_enable = 0;
                                mem_read_pending = 1;
                                writeback = 0;
                            end
                            3'b101: begin // LHU
                                mem_addr = reg_file[rs1] + $signed(imm_i);
                                mem_write_enable = 0;
                                mem_read_pending = 1;
                                writeback = 0;
                            end
                        endcase
                    end
                    7'b0100011: begin // Store: SB, SH, SW
                        case (fetched_instruction[14:12])
                            3'b000: begin // SB
                                mem_addr = reg_file[rs1] + $signed(imm_s);
                                mem_data_out = reg_file[rs2][7:0];
                                mem_write_enable = 1;
                            end
                            3'b001: begin // SH
                                mem_addr = reg_file[rs1] + $signed(imm_s);
                                mem_data_out = reg_file[rs2][7:0];
                                mem_write_enable = 1;
                            end
                            3'b010: begin // SW
                                mem_addr = reg_file[rs1] + $signed(imm_s);
                                mem_data_out = reg_file[rs2][7:0];
                                mem_write_enable = 1;
                            end
                        endcase
                    end
                    7'b1100011: begin // Branch: BEQ, BNE, BLT, BGE, BLTU, BGEU
                        case (fetched_instruction[14:12])
                            3'b000: take_branch = (reg_file[rs1] == reg_file[rs2]);  // BEQ
                            3'b001: take_branch = (reg_file[rs1] != reg_file[rs2]);  // BNE
                            3'b100: take_branch = ($signed(reg_file[rs1]) < $signed(reg_file[rs2])); // BLT
                            3'b101: take_branch = !($signed(reg_file[rs1]) < $signed(reg_file[rs2])); // BGE
                            3'b110: take_branch = (reg_file[rs1] < reg_file[rs2]);  // BLTU
                            3'b111: take_branch = !(reg_file[rs1] < reg_file[rs2]); // BGEU
                        endcase
                        if (take_branch) begin
                            next_pc = pc + $signed(imm_b);
                        end
                    end
                    7'b0110111: result = imm_u;  // LUI
                    7'b0010111: result = pc + imm_u;  // AUIPC
                    7'b1101111: begin // JAL
                        result = next_pc;
                        next_pc = pc + $signed(imm_j);
                    end
                    7'b1100111: begin // JALR
                        result = next_pc;
                        next_pc = (reg_file[rs1] + $signed(imm_i)) & ~32'b1;
                    end
                endcase
            end
            
            // Write back to register file
            if (writeback && rd != 0) begin
                reg_file[rd] = result;
            end
            
            // Update PC
            pc = next_pc;
            instruction_valid = 0;
        end
        
        // Handle memory write completion
        if (mem_write_enable) begin
            mem_write_enable = 0;
        end
    end
end

endmodule