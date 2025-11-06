// vrf 模块 (向量寄存器文件)
// 版本：支持多 Bank, VSEW 感知写入(展开), 尾部处理, 多周期写偏移 (高可读性)
// 调整：优化 Vivado 兼容性 (循环变量声明位置, 移除 automatic)
// 特性：
// - 可配置 Lane 数量和数据宽度 (LANES, DATA_WIDTH)
// - 可配置寄存器数量 (NUM_REGS)
// - **核心设计: 并行 Bank 结构，每个 Lane 对应一个物理 Bank**
// - 写操作感知元素宽度 (VSEW)，支持 8/16/32 位粒度写入 (假设 DATA_WIDTH=32)
// - 写操作支持尾部处理 (Tail Handling)，根据 vl 仅更新活跃 Lane/Bank
// - 支持多周期访问：使用内部计数器 (load_cnt, write_cnt) 作为地址偏移量, 访问长向量的不同 slice
module vrf #(
    // 参数定义:
    parameter LANES = 4,             // 并行 Lane 的数量 (应与 VEX 匹配, 也等于 Bank 数量)
    parameter DATA_WIDTH = 32,         // 每个 Lane/Bank 的数据位宽 (应与 VEX 匹配)
    parameter NUM_REGS = 12            // 每个 Bank 中的向量寄存器数量 (例如 V32)
) (
    // --- 输出端口 ---
    // 数据端口宽度根据 LANES 和 DATA_WIDTH 参数化, 聚合了所有 Bank 的输出
    output logic [LANES*DATA_WIDTH-1:0] vs1_data, // VS1 数据到 vex (所有 Bank 在 vs1_addr 读取的数据拼接而成)
    output logic [LANES*DATA_WIDTH-1:0] vs2_data, // VS2 数据到 vex (所有 Bank 在 vs2_addr 读取的数据拼接而成)
    output logic [LANES*DATA_WIDTH-1:0] vs3_data, // VS3/VD 数据读出 (所有 Bank 在 vd_addr 读取的数据拼接而成)

    // --- 输入端口 ---
    // 数据端口宽度根据 LANES 和 DATA_WIDTH 参数化, 包含所有 Bank 的写入数据
    input wire [LANES*DATA_WIDTH-1:0] vd_data,    // 来自 vd_data_src 的写回数据 (将被解包到各 Bank)

    // 地址端口位宽适应 NUM_REGS
    input wire [$clog2(NUM_REGS)-1:0] vs1_addr_i, // VS1 逻辑基地址
    input wire [$clog2(NUM_REGS)-1:0] vs2_addr_i, // VS2 逻辑基地址
    input wire [$clog2(NUM_REGS)-1:0] vd_addr_i,  // VD 逻辑基地址 (写目标或 VS3 读地址)

    // 控制信号
    input wire [1:0] vsew,               // 元素宽度 (8/16/32 位)，用于控制写操作粒度
    input wire [7:0] vl,                 // 向量长度，用于写操作时的尾部处理
    input wire [1:0] vlmul,              // 向量寄存器组倍数 (保留, 当前未使用)
    input wire [3:0] max_load_cnt,       // 最大加载计数 (用于多周期读地址递增)
    input wire [3:0] max_write_cnt,      // 最大写入计数 (用于多周期写地址偏移和结束判断)
    input wire reduction,                // (保留输入, 当前仅用于重置 load_cnt)
    input wire clk,                      // 时钟信号
    input wire rstn,                     // 复位信号，低有效
    input wire write_en,                 // 写使能信号 (非零表示写有效)
    input wire load_en                   // 加载使能 (用于读地址递增控制)
);

    // --- 本地常量和类型定义 ---
    localparam VRF_BANK_DEPTH = NUM_REGS;        // 每个 Bank 的深度 (寄存器个数)
    localparam VRF_WIDTH = LANES * DATA_WIDTH; // VRF 总数据位宽 (所有 Bank 聚合后的宽度)
    localparam ADDR_WIDTH = $clog2(NUM_REGS);    // 逻辑寄存器地址位宽
    // **重要假设**: 下面的 BYTES_PER_WORD 依赖于 DATA_WIDTH，展开的 VSEW 逻辑假设 DATA_WIDTH=32
    localparam BYTES_PER_WORD = DATA_WIDTH / 8;  // 每个字包含的字节数

    // --- 核心存储结构 ---
    // **关键**: 定义为 LANES 个 Bank，每个 Bank 是一个独立的寄存器文件
    // 结构: vrf_banks[Bank索引/Lane索引][寄存器地址]
    // Bank 索引从 0 到 LANES-1
    logic [DATA_WIDTH-1:0] vrf_banks [0:LANES-1] [0:VRF_BANK_DEPTH-1];

    // --- 地址计算和计数器逻辑 ---
    logic [2:0] load_cnt;              // 加载计数器 (多周期读地址偏移量)
    logic [2:0] write_cnt;             // 写计数器 (多周期写地址偏移量)
    logic reached_load_max;            // 读计数器达到最大值标志
    logic reached_write_max;           // 写计数器达到最大值标志
    logic [ADDR_WIDTH-1:0] vs1_addr;   // 当前周期的 VS1 逻辑寄存器地址 (基地址+偏移)
    logic [ADDR_WIDTH-1:0] vs2_addr;   // 当前周期的 VS2 逻辑寄存器地址 (基地址+偏移)
    logic [ADDR_WIDTH-1:0] vd_addr;    // 当前周期的 VD/VS3 逻辑寄存器地址 (基地址+偏移)

    // --- 加载计数器逻辑 ---
    // 控制读操作时的地址偏移量, 用于读取长向量的后续 slice
    always_ff @(posedge clk or negedge rstn) begin : load_counter_proc
        if (~rstn) begin
            load_cnt <= 'b0;
            reached_load_max <= 1'b0;
        end else begin
            if (load_en) begin // 写有效
                if (reduction) begin // reduction 操作通常只处理第一个 slice
                    load_cnt <= 3'b0;
                    reached_load_max <= 1'b0;
                end else begin
                    if (!reached_load_max) begin // 未完成写入
    
                        if ((load_cnt + 1'b1) >= max_load_cnt ) begin
                            // 最后周期: 保持偏移量, 置位标志                        
                            load_cnt <= 'b0; // 重置计数器
                            reached_load_max <= 1'b1;
                        end 
                        else begin
                            // 非最后周期: 递增偏移量，指向下一个 slice
                            load_cnt <= load_cnt + 1'b1;
                            reached_load_max <= 1'b0; //                         
                        end
                    end 
                    else begin // 已完成写入，或开始写入
                        load_cnt <= 'b0; // 重置计数器
                        reached_load_max <= 1'b0; // 重置标志
                    end
                end
            end else begin
                load_cnt <= '0;
                reached_load_max <= '0;
            end
        end
    end // load_counter_proc

    // --- 写入计数器 / 地址偏移量逻辑 ---
    // 控制写操作时的地址偏移量，实现多周期写入长向量的后续 slice
    always_ff @(posedge clk or negedge rstn) begin : write_counter_proc
        if (~rstn) begin
            write_cnt <= 'b0;
            reached_write_max <= 1'b0;
        end else begin
            if (write_en) begin // 写有效
                if (reduction) begin // reduction 操作通常只处理第一个 slice
                    write_cnt <= 3'b0;
                    reached_write_max <= 1'b0;
                end else begin
                    if (!reached_write_max) begin // 未完成写入
    
                        if (write_cnt >= (max_write_cnt - 1'b1)) begin
                            // 最后周期: 保持偏移量, 置位标志                        
                            write_cnt <= 'b0; // 重置计数器
                        end 
                        else begin
                            // 非最后周期: 递增偏移量，指向下一个 slice
                            write_cnt <= write_cnt + 1'b1;
                            reached_write_max <= 1'b0; //                         
                        end
                    end 
                    else begin // 已完成写入，或开始写入
                        write_cnt <= 'b0; // 重置计数器
                        reached_write_max <= 1'b0; // 重置标志
                    end
                end
            end
        end
    end // write_counter_proc

    // --- 逻辑地址计算 ---
    // 计算本周期实际访问的物理寄存器地址 = 逻辑基地址 + 周期偏移量
    always_comb begin : address_calculation_comb
        // --- 默认地址 ---
        vs1_addr = {ADDR_WIDTH{1'b0}}; // 避免 latch
        vs2_addr = {ADDR_WIDTH{1'b0}};
        vd_addr  = {ADDR_WIDTH{1'b0}};

        // --- 读地址计算 (VS1, VS2, VS3) ---
        // 仅当 load_en 有效且未完成所有 slice 读取时，使用偏移后的地址
        if (load_en && !reached_load_max) begin
            vs1_addr = vs1_addr_i + load_cnt;
            vs2_addr = vs2_addr_i + load_cnt;
            vd_addr = vd_addr_i + load_cnt;  // VS3 也使用读偏移
        end else if (load_en && reached_load_max) begin // 完成读取，使用最后一个 slice 的地址
            vs1_addr = vs1_addr_i + load_cnt;
            vs2_addr = vs2_addr_i + load_cnt;
            vd_addr = vd_addr_i + load_cnt;
        end else begin // load_en 无效，可能访问基地址 (偏移为0) 或无效 (根据上层逻辑)
            vs1_addr = vs1_addr_i; // 假设此时读基地址
            vs2_addr = vs2_addr_i;
            vd_addr = vd_addr_i;
        end

        // --- 写地址计算 (VD) ---
        // 写操作优先使用写计数器计算地址
        if (write_en) begin // 写使能有效
             if (!reached_write_max) begin // 写入进行中
                 vd_addr = vd_addr_i + write_cnt; // 写基地址 + 写偏移
             end else // 写入刚完成或已完成，使用最后一个 slice 的地址
                 vd_addr = vd_addr_i + write_cnt;
        end
        // 注意: 上述逻辑中，如果同时读 VS3 和写 VD，vd_addr 会被写地址覆盖。
        // 实际应用中需要明确指令行为，可能需要独立的 VS3 地址端口或更复杂的控制。
        // 当前设计假设读写操作不会在同一周期冲突 vd_addr 的计算。
 
        // 注意: 未实现地址回绕 (wrap-around)。如果基地址+偏移量超出 NUM_REGS，行为未定义。
        // 实际硬件可能需要处理这种情况 (例如报错或回绕)。
    end // address_calculation_comb

    // --- 输入数据分解 ---
    // 使用 generate 将输入的 vd_data (VRF_WIDTH 位) 分解到每个 Lane/Bank 的信号，
    // 便于在 always_ff 中按 Bank 写入。
    logic [DATA_WIDTH-1:0] vd_data_unpacked [0:LANES-1];
    genvar lane_w_unpack; // **genvar 声明在 generate 外部**
    generate
        for (lane_w_unpack = 0; lane_w_unpack < LANES; lane_w_unpack = lane_w_unpack + 1) begin : write_unpack_gen
            localparam int LSB = lane_w_unpack * DATA_WIDTH;
            localparam int MSB = LSB + DATA_WIDTH - 1;
            // 持续赋值，将 vd_data 的对应片段连接到 vd_data_unpacked 数组
            // vd_data_unpacked[0] 对应 Lane 0 的数据, vd_data_unpacked[1] 对应 Lane 1, ...
            assign vd_data_unpacked[lane_w_unpack] = vd_data[MSB:LSB];
        end
    endgenerate


    // **循环变量声明移至块开始处**
    // --- 寄存器写操作 (核心时序逻辑) ---
    // 支持 VSEW 和尾部处理，按 Bank 写入
        int lane_rst;
        int reg_idx;
        int lane_wr;
        // **移除了 automatic 关键字**
        int element_base_idx;
        logic [$bits(vl)-1:0] element_idx_of_lane;
        logic [ADDR_WIDTH-1:0] current_write_addr;
        logic [DATA_WIDTH-1:0] write_data_for_lane;
        logic [DATA_WIDTH-1:0] current_reg_value;
        logic [DATA_WIDTH-1:0] next_reg_value;    
        
    always_ff @(posedge clk or negedge rstn) begin : register_write_proc

        if (~rstn) begin
            // --- 复位逻辑 ---
            // 将所有 Bank 的所有寄存器清零
            for (lane_rst = 0; lane_rst < LANES; lane_rst = lane_rst + 1) begin
                for (reg_idx = 0; reg_idx < VRF_BANK_DEPTH; reg_idx = reg_idx + 1) begin
                    vrf_banks[lane_rst][reg_idx] <= {DATA_WIDTH{1'b0}};
                end
            end
        end else if (write_en) begin // --- 写使能有效 ---

            // 获取当前周期的目标写入物理地址 (所有 Bank 使用相同的地址)
            // logic [ADDR_WIDTH-1:0] current_write_addr; // 已移到块首
            current_write_addr = vd_addr; // vd_addr 已在组合逻辑中计算好 (基地址+写偏移)

            // 对每个 Lane (Bank) 进行检查和潜在的写入
            for (lane_wr = 0; lane_wr < LANES; lane_wr = lane_wr + 1) begin

                // --- 步骤 1: 尾部处理 (计算当前 Lane/Bank 是否在此周期活跃) ---
                logic lane_active_for_write;
                // automatic int element_base_idx; // 已移到块首, 移除 automatic
                // automatic logic [$bits(vl)-1:0] element_idx_of_lane; // 已移到块首, 移除 automatic

                element_base_idx = write_cnt * LANES; // 考虑多周期写入的偏移
                element_idx_of_lane = element_base_idx + lane_wr; // 计算本 Lane 对应的全局元素索引
                // 比较 Lane 对应的元素索引和向量长度 vl
                lane_active_for_write = (element_idx_of_lane < vl); // 如果小于 vl，则此 Lane 在此周期活跃

                // --- 步骤 2: 检查 Lane 活跃状态和地址有效性 ---
                // 只有当 Lane 活跃且目标地址在 Bank 范围内时才执行写入
                if (lane_active_for_write && (current_write_addr < VRF_BANK_DEPTH)) begin

                    // --- 步骤 3: VSEW 感知写入 ---
                    // logic [DATA_WIDTH-1:0] write_data_for_lane; // 已移到块首
                    // logic [DATA_WIDTH-1:0] current_reg_value;   // 已移到块首
                    // logic [DATA_WIDTH-1:0] next_reg_value;      // 已移到块首

                    // 获取已分解好的当前 Lane 的写入数据
                    write_data_for_lane = vd_data_unpacked[lane_wr];
                    // 读取寄存器当前值 (主要用于 VSEW 不是覆盖整个 DATA_WIDTH 的情况)
                    current_reg_value = vrf_banks[lane_wr][current_write_addr];
                    // 默认下一状态为当前值，只更新 VSEW 指定的部分
                    next_reg_value = current_reg_value; // 假设 VSEW < 32bit 时需要保留未修改部分

                    // **重要**: 下面的 case 语句假设 DATA_WIDTH = 32
                    // 如果 DATA_WIDTH 可变，需要使用更通用的逻辑 (例如循环或 generate)
                    if (DATA_WIDTH == 32) begin // 显式检查以强调假设
                        case (vsew)
                            2'b00: begin // 8-bit: 覆盖所有 4 个字节 (假设DATA_WIDTH=32)
                                next_reg_value[ 7: 0] = write_data_for_lane[ 7: 0];
                                next_reg_value[15: 8] = write_data_for_lane[15: 8];
                                next_reg_value[23:16] = write_data_for_lane[23:16];
                                next_reg_value[31:24] = write_data_for_lane[31:24];
                            end
                            2'b01: begin // 16-bit: 覆盖所有 2 个半字 (假设DATA_WIDTH=32)
                                next_reg_value[15: 0] = write_data_for_lane[15: 0];
                                next_reg_value[31:16] = write_data_for_lane[31:16];
                            end
                            2'b10: begin // 32-bit: 覆盖整个字 (假设DATA_WIDTH=32)
                                next_reg_value[31: 0] = write_data_for_lane[31: 0];
                            end
                            default: begin // 无效 VSEW: 保持当前值 (或根据策略清零/报错)
                                next_reg_value = current_reg_value; // 保守策略：保持不变
                            end
                        endcase
                    end else begin
                        // 如果 DATA_WIDTH 不是 32，需要实现通用的 VSEW 逻辑
                        // 或者在此处产生错误/警告
                        // **确保 $display 在综合时被忽略或移除**
                        // $display("Warning: VSEW write logic assumes DATA_WIDTH=32, but it is %0d", DATA_WIDTH);
                        // 在非 32 位时，默认覆盖整个 Lane/Bank 的数据
                        next_reg_value = write_data_for_lane;
                    end

                    // --- 步骤 4: 写入 VRF ---
                    // 将计算好的 next_reg_value 写入到当前 Lane (lane_wr) 对应的 Bank 中
                    // 地址为 current_write_addr
                    vrf_banks[lane_wr][current_write_addr] <= next_reg_value;

                end // if (lane_active_for_write && address_valid)
                  // else: Lane 不活跃或地址无效，对应的 Bank 在此周期不发生写入
            end // for (lane_wr...)
        end // if (write_en != 0)
        // else: write_en == 0, 寄存器保持不变 (时序逻辑特性)
    end // register_write_proc


    // --- 寄存器读操作 (核心组合逻辑) ---
    //不需要使能信号的输入，给了
    // 使用 generate 和 assign 实现并行读取所有 Bank 的数据，
    // 并将结果聚合到输出总线上。
    genvar lane_rd; // **genvar 声明在 generate 外部**
    generate
        for (lane_rd = 0; lane_rd < LANES; lane_rd = lane_rd + 1) begin : read_gen
            // 计算当前 Lane 在输出总线上的位范围 [MSB:LSB]
            localparam int LSB = lane_rd * DATA_WIDTH;
            localparam int MSB = LSB + DATA_WIDTH - 1;

            // --- 中间读信号线 (每个 Bank/Lane 的读出值) ---
            // **将 wire 改为 logic，更通用**
            logic [DATA_WIDTH-1:0] vs1_read_lane_w;
            logic [DATA_WIDTH-1:0] vs2_read_lane_w;
            logic [DATA_WIDTH-1:0] vs3_read_lane_w;

            // --- 组合逻辑读操作 ---
            // 从 Bank lane_rd 读取 vs1_addr 地址的数据，带地址边界检查
            // 所有 lane_rd 使用相同的 vs1_addr
            assign vs1_read_lane_w = (vs1_addr < VRF_BANK_DEPTH) ? vrf_banks[lane_rd][vs1_addr] : {DATA_WIDTH{1'b0}}; // 地址无效读 0
            // 从 Bank lane_rd 读取 vs2_addr 地址的数据，带地址边界检查
            // 所有 lane_rd 使用相同的 vs2_addr
            assign vs2_read_lane_w = (vs2_addr < VRF_BANK_DEPTH) ? vrf_banks[lane_rd][vs2_addr] : {DATA_WIDTH{1'b0}};
            // 从 Bank lane_rd 读取 vd_addr 地址的数据 (用于 VS3)，带地址边界检查
            // 所有 lane_rd 使用相同的 vd_addr (注意与写地址计算的潜在冲突)
            assign vs3_read_lane_w = (vd_addr < VRF_BANK_DEPTH)  ? vrf_banks[lane_rd][vd_addr]  : {DATA_WIDTH{1'b0}};

            // --- 连接到输出端口 (数据聚合/拼接) ---
            // 将 Bank lane_rd 读取的数据连接到输出总线的对应 Lane 片段
            // vs1_data[31:0]   = Bank 0 的 vs1 数据 (假设 LANES=4, DATA_WIDTH=32)
            // vs1_data[63:32]  = Bank 1 的 vs1 数据
            // vs1_data[95:64]  = Bank 2 的 vs1 数据
            // vs1_data[127:96] = Bank 3 的 vs1 数据
            assign vs1_data[MSB:LSB] = vs1_read_lane_w;
            assign vs2_data[MSB:LSB] = vs2_read_lane_w;
            assign vs3_data[MSB:LSB] = vs3_read_lane_w;
        end // for (lane_rd...)
     endgenerate // read_gen

    // --- 移除旧的逻辑 ---
    // (确认旧的地址/数据/使能信号和映射逻辑已移除 - 这部分通常指开发过程中的清理)

endmodule