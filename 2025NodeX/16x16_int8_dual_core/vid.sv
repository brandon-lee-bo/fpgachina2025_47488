
import rvv_pkg::*;

module vid (
    // 指令和操作数输出
    output logic [31:0] instr_o,
    output logic [11:0] immediate_operand,  // 跨步的步幅值
    output logic [31:0] scalar_operand,     // 加载/存储的内存地址
    output logic [4:0] vs1_addr,  
    output logic [4:0] vs2_addr,
    output logic [4:0] vd_addr,
    output logic       bus_spare,
    output logic       core_activate,

    // 向量操作的控制信号
    output logic csr_write,
    output logic vex_en,    
    output logic preserve_vl,
    output logic vrf_load,    
    output logic vrf_write,
    output logic reduction,             // 归约操作标志
    output logic [3:0] cycle_count,     // 当前指令循环计数
    output logic [3:0] max_load_cnt,    // 最大加载计数（用于加载数据）
    output logic [3:0] max_write_cnt,   // 最大写入计数（用于写入数据）
    output vreg_wb_src_t vd_data_src,   // 目标寄存器数据来源
    output vreg_addr_src_t vs3_addr_src,// 第三源寄存器地址来源
    output pe_arith_op_t pe_op,         // PE操作+-*/   
    output pe_operand_t operand_select, // 操作数选择 （arith模块利用case来给pe_data赋值）
    
    input wire clk,
    input wire rstn,
    input wire hold_id, 
    input wire [1:0] [31:0] instr_i,     //instr
    input wire [7:0] vl,
    input wire [1:0] vsew,
    input wire [1:0] vlmul,
    input wire nib_hold_req_i,

    // VLSU接口
    output logic vlsu_en_o,
    output logic vlsu_load_o,
    output logic vlsu_store_o,
    output logic vlsu_strided_o,
    input  logic vlsu_done_i,

    output logic [3:0] hold_req_o,

    //spmm指令信号
    output logic sparse_write,
    output logic sparse_load,

    //vex接口
    input  logic addr_ready,
    output logic spmm_load_done,
    input  logic spmm_compute_done,
    input  logic index_cal_done,
    input  wire  [15:0] row_index, 
    input  wire  [15:0] row_index_dense_i, //dense矩阵的行索引
    output logic load_index_o,
    input  wire  load_index_ready_i,
    input  wire  [4:0] extra_load_num_i,//这一行除了常用行之外的数据数量
    input  wire  [4:0] compute_row_data_num,//计算这一行总共的数据数量
    input  wire  [3:0] top_rows_id [4],
    input  wire  [3:0] extra_rows_id[8],
    input  logic  [3:0] compute_rows_id_i[8],

    //dense_buf接口
    output logic dense_buf_write_en_o,
    output logic dense_buf_read_en_o,//dense buffer输出数据给vrf的使能信号
    output logic [5:0] dense_buf_read_addr_o,
    output logic [5:0] dense_buf_write_addr_o,
    output logic [1:0] dense_buf_data_source_o, //0表示来自vlsu的数据，1表示来自计算完成的数据

    //dma接口
    input dma_store_done, //dma存储完成信号
    output logic dma_instr_valid_o,
    output logic dma_buf_store_o,
    output logic [7:0] dma_max_data_cnt,
    output logic dma_store_en //使能dma从外部获取下一个稀疏矩阵数据

);


enum {WAIT, EXEC, HOLD, BUS_HOLD} state, next_state;

logic [3:0] max_cycle_count;   // 多周期指令的最大周期计数
logic multi_cycle_instr;       // 是否为多周期指令
logic fix_vd_addr;             // 是否固定目标寄存器地址(部分指令如vadd或浮点存储需要)
logic scalar_operand_ready;    // 使能vlsu的辅助信号 scalar_operand更新好之后使能 不然默认是零处理不了类似1100的row_index
logic [31:0] reg_instr;        // 暂存指令
logic [15:0] dense_index_reg;      // 暂存dense矩阵的行索引
logic [3:0] dense_id_reg[4];

logic compute_done_r;//对输入的compute_done打上1拍

// Assign variables for individual parts of instructions for readability
logic [6:0] opcode;
logic [5:0] funct6;
logic [2:0] funct3;
logic [4:0] rs1;
logic [4:0] rs2;
logic [4:0] rd;

always_comb begin
    if(!nib_hold_req_i) begin
        funct6   =   instr_i[0][30:25];   // 6-bit function field   
        rs2      =   instr_i[0][24:20];   // 5-bit source register 2
        rs1      =   instr_i[0][19:15];   // 5-bit source register 1
        funct3   =   instr_i[0][14:12];   // 3-bit function field
        rd       =   instr_i[0][11:7];    // 5-bit destination register
        opcode   =   instr_i[0][6:0];     // 7-bit opcode
    end else begin
        funct6   =   funct6;   
        rs2      =   rs2;   
        rs1      =   rs1;   
        funct3   =   funct3;
        rd       =   rd;    
        opcode   =   opcode;
    end
end


// 自定义向量指令的操作码定义和不同功能
// 以下所有判断条件要加opcode和funct6放在一起以便于后续增加指令
localparam logic [6:0] V_OPCODE_SPMM                = 7'b1111000;   // 新增，用于执行spmm计算
localparam logic [5:0] V_FUNCT6_COMPUTE             = 6'b000000;    // opcode下的compute功能
localparam logic [5:0] V_FUNCT6_LOAD                = 6'b000001;    // opcode下的Load功能
localparam logic [5:0] V_FUNCT6_STORE               = 6'b000010;    // opcode下的store功能  把dense buf的数据存出去
localparam logic [5:0] V_FUNCT6_ADD                 = 6'b000011;    // opcode下的add功能 组合分矩阵
localparam logic [5:0] V_FUNCT6_SPMM_LOAD           = 6'b000100;    // opcode下的spmm load功能
localparam logic [5:0] V_FUNCT6_CAL_INDEX           = 6'b000101;    // opcode下的计算所有的row_index功能
localparam logic [5:0] V_FUNCT6_FIX_ROW             = 6'b000110;    // opcode下的固定常用行功能 todo
localparam logic [5:0] V_FUNCT6_SPMM_LOAD_VECTOR    = 6'b000111; // opcode下的spmm load vector功能 todo
localparam logic [5:0] V_FUNCT6_SPMM_STORE_VECTOR   = 6'b001000; // opcode下的spmm store vector功能 todo

// 计数器 计算row_index当中1的数量
// 计数器：计算row_index中1的数量（仅在addr_ready时更新）
// 这个减法器计算出来的结果跟下面同步 下面用的是number_rows的旧值 所以number_rows==1结束或者用number_rows!=1更新信号
// 结束逻辑是vlsu_done && number_rows == 1(即使一行也满足)
logic [5:0] number_rows;
logic [15:0] row_index_reg;

logic [15:0] extra_row_index;
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        extra_row_index <= '0;
    end else begin
        if(load_index_ready_i && opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_LOAD) begin
            extra_row_index <= ~dense_index_reg & row_index;
        end else begin
            extra_row_index <= extra_row_index;
        end
    end
end

logic load_index_ready_r;
always_ff@(posedge clk or negedge rstn) begin
    if(~rstn) begin
        load_index_ready_r <= '0;
    end else begin
        load_index_ready_r <= load_index_ready_i;
    end
end




assign row_index_reg = (pe_op == PE_SPMM_FIX_ROW) ? dense_index_reg : extra_row_index; // 固定行索引时使用dense矩阵的行索引

always_ff @(posedge clk or negedge rstn ) begin
    if (~rstn) begin
        number_rows <= 3'b0;
    end else begin
        if ( vlsu_done_i && (state == HOLD) && ((opcode == V_OPCODE_SPMM) && (funct6 == V_FUNCT6_LOAD) || (pe_op == PE_SPMM_FIX_ROW))) begin
            number_rows <= number_rows - 1'b1;
        end else if ((state == EXEC) && ((load_index_ready_i && (opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_LOAD)) || (pe_op == PE_SPMM_FIX_ROW))) begin  //这一块只能赋值一次 也就是在exec的时候 后面进入了hold 开始用递减逻辑
            number_rows <= row_index_reg[0]  + row_index_reg[1]  + row_index_reg[2]  + row_index_reg[3] + 
                           row_index_reg[4]  + row_index_reg[5]  + row_index_reg[6]  + row_index_reg[7] + 
                           row_index_reg[8]  + row_index_reg[9]  + row_index_reg[10] + row_index_reg[11] + 
                           row_index_reg[12] + row_index_reg[13] + row_index_reg[14] + row_index_reg[15] ;
        end
    end
end

//传给vex的spmm_load完成信号
assign spmm_load_done = ((state == HOLD) && vlsu_done_i && (number_rows == 1)) || number_rows == 0 && (state == HOLD) && funct6 == V_FUNCT6_LOAD; //number_rows==0说明只有一行


//计数器 完成三次load则拉高信号，转换状态，完成load_vector指令。
//会在load_vector_count变成11了之后下一个周期变成0.状态机转换是组合逻辑。
logic [2:0] load_vector_count;
always_ff @(posedge clk or negedge rstn) begin
    if (~rstn) begin
        load_vector_count <= 3'b0;
    end else if (dense_buf_read_en_o && funct6 == V_FUNCT6_SPMM_LOAD_VECTOR && opcode == V_OPCODE_SPMM) begin
        if(load_vector_count == 3'b011)
        load_vector_count <= '0;
        else
        load_vector_count <= load_vector_count + 1;
    end
    else load_vector_count <= '0;
end

//load dense buff的地址，用指令的rd
//densebuff访问地址 每个更新 一个矩阵16个rows rd指向第一个rows。

localparam OFFSET_MATRIX = 16;
localparam OFFSET_FLEXIBLE_MATRIX = 12;  //dnnsebuf存放每次load的区域


// 状态机更新
//思路：把右矩阵从上到下存，从0x0000开始存 也就是对应spmmload指令的标量操作数恒等于32'0
//在数据准备 好的时候在把第一个要取的行的地址赋值给scalar_operand
always_ff @(posedge clk or negedge rstn) begin
    if (~rstn) begin
        state <= WAIT;
        reg_instr <= 32'b0;
        scalar_operand <= 32'b0;
    end else begin
        state <= next_state;
        
        // 修改后的reg_instr更新逻辑
        if (next_state != HOLD) begin
            // 如果是SPMM load指令且addr_ready未到来，保持当前指令
            if ((reg_instr[6:0] == V_OPCODE_SPMM) && 
                (reg_instr[30:25] == V_FUNCT6_LOAD) && 
                !scalar_operand_ready) begin
                reg_instr <= reg_instr;  // 保持当前值
            end 
            // 其他情况正常更新指令
            else begin
                reg_instr <= instr_i[0];
            end
        end

// 保持原有的scalar_operand逻辑不变
if ((load_index_ready_i && (opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_LOAD)) || pe_op == PE_SPMM_FIX_ROW) begin
    // 第一优先级：非HOLD状态时的row_index编码
    if (state == EXEC) begin
        scalar_operand_ready = 1'b1;
        if (row_index_reg[0]) begin
            scalar_operand <= instr_i[1] + 32'd0;
        end else if (row_index_reg[1]) begin
            scalar_operand <= instr_i[1] + 32'd4*4;
        end else if (row_index_reg[2]) begin
            scalar_operand <= instr_i[1] + 32'd8*4;
        end else if (row_index_reg[3]) begin
            scalar_operand <= instr_i[1] + 32'd12*4;
        end else if (row_index_reg[4]) begin
            scalar_operand <= instr_i[1] + 32'd16*4;
        end else if (row_index_reg[5]) begin
            scalar_operand <= instr_i[1] + 32'd20*4;
        end else if (row_index_reg[6]) begin
            scalar_operand <= instr_i[1] + 32'd24*4;
        end else if (row_index_reg[7]) begin
            scalar_operand <= instr_i[1] + 32'd28*4;
        end else if (row_index_reg[8]) begin
            scalar_operand <= instr_i[1] + 32'd32*4;
        end else if (row_index_reg[9]) begin
            scalar_operand <= instr_i[1] + 32'd36*4;
        end else if (row_index_reg[10]) begin
            scalar_operand <= instr_i[1] + 32'd40*4;
        end else if (row_index_reg[11]) begin
            scalar_operand <= instr_i[1] + 32'd44*4;
        end else if (row_index_reg[12]) begin
            scalar_operand <= instr_i[1] + 32'd48*4;
        end else if (row_index_reg[13]) begin
            scalar_operand <= instr_i[1] + 32'd52*4;
        end else if (row_index_reg[14]) begin
            scalar_operand <= instr_i[1] + 32'd56*4;
        end else if (row_index_reg[15]) begin
            scalar_operand <= instr_i[1] + 32'd60*4;
        end
    end
    // 第二优先级：HOLD状态处理
    else if (vlsu_done_i && number_rows != 1) begin
        case (scalar_operand)
            instr_i[1] + 32'd0: begin
                if (row_index_reg[1]) scalar_operand <= instr_i[1] + 32'd4*4;
                else if (row_index_reg[2]) scalar_operand <= instr_i[1] + 32'd8*4;
                else if (row_index_reg[3]) scalar_operand <= instr_i[1] + 32'd12*4;
                else if (row_index_reg[4]) scalar_operand <= instr_i[1] + 32'd16*4;
                else if (row_index_reg[5]) scalar_operand <= instr_i[1] + 32'd20*4;
                else if (row_index_reg[6]) scalar_operand <= instr_i[1] + 32'd24*4;
                else if (row_index_reg[7]) scalar_operand <= instr_i[1] + 32'd28*4;
                else if (row_index_reg[8]) scalar_operand <= instr_i[1] + 32'd32*4;
                else if (row_index_reg[9]) scalar_operand <= instr_i[1] + 32'd36*4;
                else if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd4*4: begin
                if (row_index_reg[2]) scalar_operand <= instr_i[1] + 32'd8*4;
                else if (row_index_reg[3]) scalar_operand <= instr_i[1] + 32'd12*4;
                else if (row_index_reg[4]) scalar_operand <= instr_i[1] + 32'd16*4;
                else if (row_index_reg[5]) scalar_operand <= instr_i[1] + 32'd20*4;
                else if (row_index_reg[6]) scalar_operand <= instr_i[1] + 32'd24*4;
                else if (row_index_reg[7]) scalar_operand <= instr_i[1] + 32'd28*4;
                else if (row_index_reg[8]) scalar_operand <= instr_i[1] + 32'd32*4;
                else if (row_index_reg[9]) scalar_operand <= instr_i[1] + 32'd36*4;
                else if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd8*4: begin
                if (row_index_reg[3]) scalar_operand <= instr_i[1] + 32'd12*4;
                else if (row_index_reg[4]) scalar_operand <= instr_i[1] + 32'd16*4;
                else if (row_index_reg[5]) scalar_operand <= instr_i[1] + 32'd20*4;
                else if (row_index_reg[6]) scalar_operand <= instr_i[1] + 32'd24*4;
                else if (row_index_reg[7]) scalar_operand <= instr_i[1] + 32'd28*4;
                else if (row_index_reg[8]) scalar_operand <= instr_i[1] + 32'd32*4;
                else if (row_index_reg[9]) scalar_operand <= instr_i[1] + 32'd36*4;
                else if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd12*4: begin
                if (row_index_reg[4]) scalar_operand <= instr_i[1] + 32'd16*4;
                else if (row_index_reg[5]) scalar_operand <= instr_i[1] + 32'd20*4;
                else if (row_index_reg[6]) scalar_operand <= instr_i[1] + 32'd24*4;
                else if (row_index_reg[7]) scalar_operand <= instr_i[1] + 32'd28*4;
                else if (row_index_reg[8]) scalar_operand <= instr_i[1] + 32'd32*4;
                else if (row_index_reg[9]) scalar_operand <= instr_i[1] + 32'd36*4;
                else if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd16*4: begin
                if (row_index_reg[5]) scalar_operand <= instr_i[1] + 32'd20*4;
                else if (row_index_reg[6]) scalar_operand <= instr_i[1] + 32'd24*4;
                else if (row_index_reg[7]) scalar_operand <= instr_i[1] + 32'd28*4;
                else if (row_index_reg[8]) scalar_operand <= instr_i[1] + 32'd32*4;
                else if (row_index_reg[9]) scalar_operand <= instr_i[1] + 32'd36*4;
                else if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd20*4: begin
                if (row_index_reg[6]) scalar_operand <= instr_i[1] + 32'd24*4;
                else if (row_index_reg[7]) scalar_operand <= instr_i[1] + 32'd28*4;
                else if (row_index_reg[8]) scalar_operand <= instr_i[1] + 32'd32*4;
                else if (row_index_reg[9]) scalar_operand <= instr_i[1] + 32'd36*4;
                else if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd24*4: begin
                if (row_index_reg[7]) scalar_operand <= instr_i[1] + 32'd28*4;
                else if (row_index_reg[8]) scalar_operand <= instr_i[1] + 32'd32*4;
                else if (row_index_reg[9]) scalar_operand <= instr_i[1] + 32'd36*4;
                else if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd28*4: begin
                if (row_index_reg[8]) scalar_operand <= instr_i[1] + 32'd32*4;
                else if (row_index_reg[9]) scalar_operand <= instr_i[1] + 32'd36*4;
                else if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd32*4: begin
                if (row_index_reg[9]) scalar_operand <= instr_i[1] + 32'd36*4;
                else if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd36*4: begin
                if (row_index_reg[10]) scalar_operand <= instr_i[1] + 32'd40*4;
                else if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd40*4: begin
                if (row_index_reg[11]) scalar_operand <= instr_i[1] + 32'd44*4;
                else if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd44*4: begin
                if (row_index_reg[12]) scalar_operand <= instr_i[1] + 32'd48*4;
                else if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd48*4: begin
                if (row_index_reg[13]) scalar_operand <= instr_i[1] + 32'd52*4;
                else if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd52*4: begin
                if (row_index_reg[14]) scalar_operand <= instr_i[1] + 32'd56*4;
                else if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            instr_i[1] + 32'd56*4: begin
                if (row_index_reg[15]) scalar_operand <= instr_i[1] + 32'd60*4;
            end
            default: scalar_operand <= scalar_operand;
        endcase
    end
        end else begin
            scalar_operand <= instr_i[1];
        end
    end
end

logic nib_hold_req_r;
always_ff @(posedge clk or negedge rstn) begin
    if(!rstn) begin
        nib_hold_req_r <= '0;
    end else begin
        nib_hold_req_r <= nib_hold_req_i;
    end
end

logic dense_buf_read_en_o_tag;  //load_tmp下的exec转hold逻辑

// 状态机组合逻辑
always_comb
begin
    next_state = state;
    case ( state )
        WAIT:
        begin
            if (hold_id) begin
                next_state = HOLD;      // 非hold时进入 EXEC 状态
                hold_req_o <= 4'b0000;     
                core_activate <= '0;       
            end
            else begin
                next_state = EXEC;  //hold拉低的时候进入exec开始执行状态 hold恒为0直接开始
                hold_req_o <= 4'b0000;    
                core_activate <= '1; 
            end             
        end
        EXEC:  //准备开始执行一个指令 每个指令对应的都不同 在下面case当中 
        begin
            if (vlsu_en_o | (vex_en & multi_cycle_instr & funct6 != V_FUNCT6_COMPUTE) | dma_instr_valid_o |  (~extra_load_valid & (funct6 == V_FUNCT6_COMPUTE && opcode == V_OPCODE_SPMM) && (compute_row_data_num != 0) ))begin //如果出现vlsu或多周期vex指令，进入 HOLD 状态
                next_state = HOLD;      
                hold_req_o <= 4'b0001;
                core_activate <= 1'b1;
            end else if (dense_buf_read_en_o_tag && pe_op == PE_SPMM_LOAD_VECTOR) begin
                next_state <= HOLD;
                hold_req_o <= 4'b0001;
                core_activate <= 1'b1;
            end
            else if(funct6 == V_FUNCT6_LOAD) begin
                hold_req_o <= 4'b0001;
                next_state <= EXEC;
                core_activate <= 1'b0;  
            end else if(number_rows == 0 && funct6 == V_FUNCT6_LOAD) begin
                hold_req_o <= 4'b0000;
                next_state <= WAIT;
            end else if(spmm_compute_done) begin
                hold_req_o <= 4'b0000;
                next_state <= WAIT ;
            end else if(funct6 == V_FUNCT6_COMPUTE && opcode == V_OPCODE_SPMM) begin
                hold_req_o <= 4'b0001;
                next_state <= EXEC;
                core_activate <= 1'b0;
            end else begin      
                next_state = EXEC;    // 否则继续执行
                hold_req_o <= 4'b0000; 
                core_activate <= 1'b0;
            end              
        end
        
        HOLD:  //加载或计算的过程当中是hold  
        begin
            if(vlsu_done_i && number_rows == 1 && funct6 == V_FUNCT6_FIX_ROW && opcode == V_OPCODE_SPMM) begin  //load指令当中 load完成的话则vlsu会发送vlsu_done_i的信号
                next_state = EXEC;               // VLSU 完成时返回 EXEC
                hold_req_o <= 4'b0000;
                core_activate <= 1'b1;
            end 
            else if( funct6 == V_FUNCT6_LOAD && vlsu_done_i && number_rows == 1 || (funct6 == V_FUNCT6_LOAD && number_rows == 0)) begin
                next_state = WAIT;               // VLSU 完成时返回 EXEC
                hold_req_o <= 4'b0000;
                core_activate <= 1'b1;
            end
            else if (funct6 == V_FUNCT6_STORE && vlsu_done_i && opcode == V_OPCODE_SPMM) begin  //store结束，在hold并且vlsu完成写入dram，转回到exec状态
                next_state = EXEC;    
                hold_req_o <= 4'b0000;
                core_activate <= 1'b1;
            end        
            else if(spmm_compute_done && nib_hold_req_i) begin
                next_state = BUS_HOLD;
                hold_req_o <= 4'b0001;
            end
            else if (compute_done_r && (nib_hold_req_r && !nib_hold_req_i)) begin
                next_state = EXEC;
                core_activate <= 1'b1;
            end 
            else if (spmm_compute_done ) begin
                next_state = WAIT;
                hold_req_o <= 4'b0000;
                core_activate <= 1'b1;
            end else if((funct6 == V_FUNCT6_SPMM_LOAD && dma_store_done) || index_cal_done) begin 
                next_state <= EXEC; // 如果DMA存储完成，返回EXEC状态
                hold_req_o <= 4'b0000;
                core_activate <= 1'b1;
            end else if(nib_hold_req_r && !nib_hold_req_i) begin
                next_state <= EXEC;
                hold_req_o <= 4'b0000;
                core_activate <= 1'b1;
            end else if ((opcode == V_OPCODE_SPMM) & (funct6 == V_FUNCT6_SPMM_LOAD_VECTOR) & (load_vector_count == 3'b010) )begin //三次load之后跳转到exec接收下一个指令
                next_state <= EXEC;
                hold_req_o <= 4'b0000;
                core_activate <= 1'b1;
            end else if ((opcode == V_OPCODE_SPMM) & (funct6 == V_FUNCT6_ADD)) begin
                next_state <= EXEC;
                hold_req_o <= 4'b0000;
                core_activate <= 1'b1;
            end else begin
                next_state = HOLD;
                hold_req_o <= 4'b0001;
                core_activate <= core_activate;
            end
        end
            
        BUS_HOLD:       
        begin
            if(funct6 == V_FUNCT6_COMPUTE && (nib_hold_req_r && !nib_hold_req_i)) begin
                next_state = EXEC;  
                hold_req_o <= 4'b0000;
            end else begin
                next_state = BUS_HOLD;
            end
        end

    endcase
end

// 向量寄存器地址生成和周期计数 
always_ff @(posedge clk or negedge rstn) begin
    if (~rstn) begin
        cycle_count <= '0;            // 复位周期计数器
    end else begin
        if ((next_state == HOLD) && (vex_en) ) // 如果在执行vlsu或多周期vex指令
            cycle_count <= cycle_count + 1'b1;         //记录当前指令的执行周期数
        else if (state == WAIT) // 如果在等待状态
            cycle_count <= '0;                          // 重置周期计数器
        else
            cycle_count <= '0;                // 否则保持不变
    end
end

always_comb begin
    case (vsew)
        3'd2: max_cycle_count = vl[5:2];   // LMUL = 1，最大加载计数器值为 vl 的低两位
        3'd1: max_cycle_count = vl[6:3];   // LMUL = 2，最大加载计数器值为 vl 的低三位
        3'd0: max_cycle_count = vl[7:4];   // LMUL = 4，最大加载计数器值为 vl 的低四位
        default: max_cycle_count = '0;     // 默认值
    endcase
end

//由于densebuf读数据是组合逻辑，vid内部地址更新又是时序逻辑所以有效数据慢一拍
//使能load_vec的信号比dense_buf_read_en_o延迟一拍 


// vex <--> vrf 
// 计算最大加载计数器值（根据vl和sew设置）, gemv只有一次write
always_comb begin
    if(opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_COMPUTE) begin
        //max_load_cnt = row_index_reg[0] + row_index_reg[1] + row_index_reg[2] + row_index_reg[3] + row_index_reg[4] 
        //+ row_index_reg[5] + row_index_reg[6] + row_index_reg[7] + row_index_reg[8] + row_index_reg[9] + row_index_reg[10] 
        //+ row_index_reg[11] + row_index_reg[12] + row_index_reg[13] + row_index_reg[14] + row_index_reg[15];
        max_load_cnt = '0;
    end else begin
        case (vsew)
            3'd2: max_load_cnt = vl[5:2]; // LMUL = 1，最大加载计数器值为 vl 的低两位
            3'd1: max_load_cnt = vl[6:3]; // LMUL = 2，最大加载计数器值为 vl 的低三位
            3'd0: max_load_cnt = vl[7:4]; // LMUL = 4，最大加载计数器值为 vl 的低四位
            default: max_load_cnt = '0;     // 默认值
        endcase
    end
    case (vsew)
        3'd2: max_write_cnt = vl[5:2]; // LMUL = 1，最大加载计数器值为 vl 的低两位
        3'd1: max_write_cnt = vl[6:3]; // LMUL = 2，最大加载计数器值为 vl 的低三位
        3'd0: max_write_cnt = vl[7:4]; // LMUL = 4，最大加载计数器值为 vl 的低四位
        default: max_write_cnt = '0;     // 认值
    endcase    
end

always_comb begin

end

//由于现在读vd需要一个周期 但是加法需要的是组合逻辑 不能等一个周期 所以在op为add的时候用组合逻辑给vd_addr，其他时候维持不变，打一拍之后再给vd_addr
//把除了输出的和下面这一行的vd_addr都变成vd_addr_r todo
assign vd_addr = (pe_op == PE_ARITH_ADD) ?  rd : vd_addr_r ; 
logic [4:0] vd_addr_r;

// 根据向量长度和操作宽度计算最大循环次数
logic [7:0] vl_zero_indexed;
// 寄存器地址处理逻辑
logic [4:0] rd_tep; // 寄存器地址临时存储
always_ff @(posedge clk or negedge rstn) begin
    if (~rstn) begin
        rd_tep <= 'b0;
        vd_addr_r <= 'b0;
    end else begin
            // 更新rd_tep的逻辑保持不变
            if (funct6 == V_FUNCT6_STORE  && opcode == V_OPCODE_SPMM) begin
                rd_tep <= rd;
            end
            // 更新vd_addr的统一逻辑 跟scalar_operand差不多
            else if (load_index_ready_i && !extra_load_valid) begin
                //第一级
                    if(next_state != HOLD)
                    vd_addr_r <= 0;  //todo存行的起始向量寄存器的地址 16. 可变的参数 后面可以在pkg里面设置一下
                    // 第二级 后续在HOLD的过程当中
                    else if (next_state == HOLD && vlsu_done_i && number_rows != 1) begin
                        vd_addr_r <= vd_addr_r + 1; // vd_addr的加逻辑 一开始赋值逻辑在前面 每次加载完成递增
                    end
            end 
            //更新dense buf来的数据存到vec的哪个地方。从0开始存。存3个数，012  fixme
            else if (dense_buf_read_en_o_tag &&  funct6 == V_FUNCT6_SPMM_LOAD_VECTOR && opcode == V_OPCODE_SPMM )begin
                vd_addr_r <= '0;  //清零逻辑
            end
            else if (dense_buf_read_en_o && funct6 == V_FUNCT6_SPMM_LOAD_VECTOR && opcode == V_OPCODE_SPMM) begin
                vd_addr_r <= vd_addr_r + 1; //densebuf_read_en拉高肯定是在hold状态
            end
            // 更新vd_addr的统一逻辑 跟scalar_operand差不多
            else if (addr_ready) begin
                //第一级
                if(next_state != HOLD)
                vd_addr_r <= 5'b10000;  //todo存行的起始向量寄存器的地址 16. 可变的参数 后面可以在pkg里面设置一下
                // 第二级 后续在HOLD的过程当中
                else if (next_state == HOLD && vlsu_done_i && number_rows != 1) begin
                    vd_addr_r <= vd_addr_r + 1; // vd_addr的加逻辑 一开始赋值逻辑在前面 每次加载完成递增
                end
            end
            else begin
                // 其他指令的正常处理
                if (funct6 == V_FUNCT6_STORE && opcode == V_OPCODE_SPMM) begin
                    vd_addr_r <= fix_vd_addr ? rd : rd_tep;   //store的时候把rd给到vd_addr
                end else if(funct6 == V_FUNCT6_FIX_ROW && opcode == V_OPCODE_SPMM) begin
                    if(state != HOLD && !vlsu_en_o) begin
                        vd_addr_r <= '0;  //todo存行的起始向量寄存器的地址 16. 可变的参数 后面可以在pkg里面设置一下
                        // 第二级 后续在HOLD的过程当中
                    end else if (next_state == HOLD && vlsu_done_i && number_rows != 1) begin
                        vd_addr_r <= vd_addr_r + 1; // vd_addr的加逻辑 一开始赋值逻辑在前面 每次加载完成递增
                    end else begin
                        vd_addr_r <= vd_addr_r; //保持不变
                    end
                end else if(funct6 == V_FUNCT6_COMPUTE && opcode == V_OPCODE_SPMM) begin
                    vd_addr_r <= dense_buf_read_count + 4; 
                end else begin
                    vd_addr_r <= rd; // 普通load指令  目标寄存器的地址
                end
            end
    end
end


logic [5:0] dense_read_addr;
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        dense_read_addr <= '0;
    end else begin
        if(funct6 == V_FUNCT6_COMPUTE && opcode == V_OPCODE_SPMM) begin
            dense_read_addr <= dense_buf_read_count; // 计算指令  目标寄存器的地址
        end else begin
            dense_read_addr <= '0;
        end
    end
end

logic [5:0] dense_write_addr;
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        dense_write_addr <= 6'd12;
    end else begin
        if(funct6 == V_FUNCT6_COMPUTE && opcode == V_OPCODE_SPMM) begin
            if(compute_done_r) begin
                dense_write_addr <= dense_write_addr + 1; // 计算指令  目标寄存器的地址
            end else begin
                dense_write_addr <= dense_write_addr;
            end
        end else begin
            dense_write_addr <= dense_write_addr;
        end
    end
end



//延迟一周期结束compute阶段的hold进exec
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        compute_done_r <= '0;
    end else begin
        compute_done_r <= spmm_compute_done;
    end
end

// 组合逻辑部分
always_comb begin
    // VL计算保持不变
    vl_zero_indexed = vl - 1'b1;
    
    // 源寄存器地址生成保持不变
    vs1_addr = rs1;

    
    // 立即数生成保持不变
    if (funct3 == 3'b111) begin
        immediate_operand = reg_instr[31:20];
    end else begin
        immediate_operand = {'0, reg_instr[19:15]};
    end
end
//单独修改vs2_addr生成逻辑
always_comb begin
    if(pe_op == PE_SPMM_COMPUTE) begin
        if(compute_load_extra) begin
            vs2_addr = 4 + extra_load_count;
        end else if(compute_load_stationary) begin
            vs2_addr = compute_load_stationary_addr;
        end else begin
            vs2_addr = vs2_addr;
        end
    end else begin
        vs2_addr = rs2;
    end
end

//给compute取数据设置一个计数器,这个计数器是用来指向放在不固定位置的行的
logic [4:0] extra_load_count;
logic compute_load_finish;
logic compute_load_extra = 0;
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn)begin
        extra_load_count <= '0;
        compute_load_finish <= '0;
    end else begin
        if(pe_op == PE_SPMM_COMPUTE && (extra_load_count >= extra_load_num_i - 1)) begin
            extra_load_count <= '0;
            compute_load_finish <= 1'b1;
        end else if(pe_op == PE_SPMM_COMPUTE && (compute_rows_id_i[compute_cnt - 1] == extra_rows_id[extra_load_count])) begin
            extra_load_count <= extra_load_count + 1;
            compute_load_finish <= 1'b0;
        end
    end
end

//计数器，这个计数器是用来指向当前计算到第几个数了
logic [4:0] compute_cnt;
logic compute_load_done;
logic compute_load_stationary;
logic [2:0] compute_load_stationary_addr;
logic compute_valid;
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        compute_cnt <= '0;
        compute_load_done <= '0;
    end else begin
        if(pe_op == PE_SPMM_COMPUTE && !compute_load_done && (compute_cnt == compute_row_data_num) )begin
            compute_cnt <= '0; 
            compute_load_done <= 1'b1;
            compute_valid <= 1'b0;
        end else if(pe_op == PE_SPMM_COMPUTE && !compute_load_done && (compute_cnt <= compute_row_data_num) && dense_buf_read_en_o) begin
            if(compute_rows_id_i[compute_cnt - 1] == extra_rows_id[extra_load_count]) begin
                compute_load_done <= 1'b0;
            end
            compute_cnt <= compute_cnt + 1;
            compute_load_done <= 1'b0;
            compute_valid = 1'b1;
        end else if(pe_op == PE_SPMM_COMPUTE) begin
            compute_cnt <= compute_cnt; 
            compute_load_done <= compute_load_done;
            compute_valid <= compute_valid;
        end  else begin
            compute_cnt <= '0;
            compute_load_done <= 1'b0;
            compute_valid <= 1'b0;
        end
    end
end

always_comb begin
   if(pe_op == PE_SPMM_COMPUTE && compute_load_done )begin
            compute_load_extra = 1'b0;
            compute_load_stationary = 1'b0;
            compute_load_stationary_addr <= '0;
        end else if(pe_op == PE_SPMM_COMPUTE && !compute_load_done && (compute_cnt <= compute_row_data_num)) begin
            if((compute_rows_id_i[compute_cnt - 1] == extra_rows_id[extra_load_count]) && compute_valid) begin
                compute_load_extra = 1'b1;
                compute_load_stationary = 1'b0;
                compute_load_stationary_addr <= '0;
            end else if((compute_rows_id_i[compute_cnt - 1] != extra_rows_id[extra_load_count]) && compute_valid) begin
                compute_load_stationary = 1'b1;
                compute_load_extra = 1'b0;
                for(int j = 0; j < 4; j++) begin
                    if(compute_rows_id_i[compute_cnt - 1] == top_rows_id[j]) begin
                        compute_load_stationary_addr = j;
                    end else begin
                        compute_load_stationary_addr = compute_load_stationary_addr;
                    end
                end
            end else begin
                compute_load_extra = 1'b0;
                compute_load_stationary = 1'b0;
            end
        end 
end



localparam DENSE_WB_SRC_ARITH = 1;
localparam DENSE_WB_SRC_VLSU  = 0;

always_ff @(posedge clk or negedge rstn) begin
    if (~rstn) begin
        vd_data_src <= VREG_WB_SRC_ARITH;            // 复位
        vs3_addr_src = VS3_ADDR_SRC_DECODE;
    end else begin
        if (opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_STORE) begin
            dense_buf_data_source_o = DENSE_WB_SRC_VLSU;
            vd_data_src = VREG_WB_SRC_MEMORY;              
            vs3_addr_src = VS3_ADDR_SRC_DECODE;          // 存储指令时，数据来源于 VLSU
        end else if(opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_LOAD) begin
            dense_buf_data_source_o = DENSE_WB_SRC_VLSU;
            vd_data_src <= VREG_WB_SRC_ARITH;         //数据从dense_buffer来
            vs3_addr_src = VS3_ADDR_SRC_DECODE;        //地址从rd来
        end else if (opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_FIX_ROW) begin
            dense_buf_data_source_o = DENSE_WB_SRC_VLSU;
            vd_data_src <= VREG_WB_SRC_MEMORY;         //数据从vlsu来
            vs3_addr_src = VS3_ADDR_SRC_DECODE;        //地址从rd来
             //选择的目标寄存器地址来源于load的rd 把rd规定与32'0（外部内存）也就是存右矩阵的第一个
        end else if (opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_COMPUTE) begin
            dense_buf_data_source_o = DENSE_WB_SRC_ARITH;
            vd_data_src <= VREG_WB_SRC_ARITH;         //数据从vex来
            vs3_addr_src = VS3_ADDR_SRC_DECODE;        //地址从rd来
        end else if (opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_ADD && funct3 == '0)begin
            dense_buf_data_source_o = DENSE_WB_SRC_ARITH;
            vd_data_src <= VREG_WB_SRC_ARITH;         //数据从vex来
            vs3_addr_src = VS3_ADDR_SRC_DECODE;        //地址从rd来
        end  else if (opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_ADD && funct3 == 3'b001)begin
            vd_data_src <= VREG_WB_SRC_ARITH_LANE;     //数据从vex来
            vs3_addr_src = VS3_ADDR_SRC_DECODE;        //地址从rd来
        end  else if (opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_SPMM_LOAD_VECTOR) begin 
            vd_data_src <= VREG_WB_SRC_ARITH;         //数据从dense buff里面来  现在没有从arith里来的 所以原先是artih的现在都是从buffer来，名字还没改
            vs3_addr_src = VS3_ADDR_SRC_DECODE;        //地址从rd里面来 
        end else  begin
            vd_data_src <= VREG_WB_SRC_ARITH;  
            vs3_addr_src = VS3_ADDR_SRC_DECODE;     // 默认数据来源为算术运算结果
        end
    end
end

localparam OFFSET_TEMP_MATRIX = 44;  //12行数据+两个矩阵（32行

////////////////////////////////////////////////////////////////////////////////
// ACCELERATOR CONTROL SIGNALS
always_comb
begin
    // 当不处于执行状态时，为各控制信号赋予默认值
    dense_buf_read_en_o_tag = 1'b0;
    dense_buf_read_en_o = 1'b0;  //默认条件下不读dense buf
    csr_write = 1'b0;              // 默认不写CSR寄存器
    vex_en = 1'b0;                 // 默认不启用VEX模块
    preserve_vl = 1'b0;            // 默认不保留当前矢量长度（VL）
    vrf_write = 1'b0;              // 默认不写向量寄存器
    pe_op = PE_SPMM_COMPUTE;          // 默认PE（处理单元）操作设为
    operand_select = PE_OPERAND_VS1; // 默认操作数选择为VS1寄存器
    multi_cycle_instr = 1'b0;       // 默认不是多周期指令
    reduction = 1'b0;              // 默认不进行归约操作

    vrf_load = 1'b0;               // 默认不加载向量寄存器
    vrf_write = 1'b0;              // 默认不写入向量寄存器

    vlsu_en_o = 1'b0;              // 默认禁用向量加载/存储单元（VLSU）
    vlsu_load_o = 1'b0;            // 默认不进行加载操作
    vlsu_store_o = 1'b0;           // 默认不进行存储操作
    vlsu_strided_o = 1'b0;         // 默认不进行跨步（strided）加载/存储
    load_index_o = 1'b0;          // 默认不加载索引
    dense_buf_write_en_o  = 1'b0;  //默认densebuf store 不使能

    fix_vd_addr = 1'b0;            // 默认不固定目标寄存器地址

    if (state == EXEC) begin
        case (opcode)
            V_OPCODE_SPMM:begin
                case (funct6)
                    V_FUNCT6_CAL_INDEX : begin // 计算行索引
                        dma_instr_valid_o = 1'b0;
                        multi_cycle_instr = 1'b1;
                        vex_en = 1'b1;            //这两句用来转exec到hold
                        pe_op = PE_SPMM_CAL_INDEX;     //vex的工作模式 vex todo  随便改的 目的是让spmm_done拉低一下
                        vrf_load = 1'b0;          //trgger vrf start load data  ， write_en
                        sparse_load = 1'b1;
                        vrf_write = 1'b0;          //组合逻辑直接算完直接写入 不用vex回传一个信号
                        dma_store_en <= 1'b1;
                        dma_max_data_cnt = 35;
                    end
                    V_FUNCT6_FIX_ROW : begin // 固定行
                        dma_instr_valid_o = 1'b0;
                        multi_cycle_instr = 1'b1;
                        vex_en = 1'b0;            //这两句用来转exec到hold
                        pe_op = PE_SPMM_FIX_ROW;     //vex的工作模式 vex todo  随便改的 目的是让spmm_done拉低一下
                        vrf_load = 1'b0;          //trgger vrf start load data  ， write_en
                        sparse_load = 1'b0;
                        vlsu_en_o = 1'b1;
                        vlsu_load_o = 1'b1;
                        dma_store_en = 1'b0;
                        operand_select = PE_OPERAND_CSR; // 其中一个操作数来自CSR寄存器（稀疏矩阵数据）
                    end
                    V_FUNCT6_COMPUTE: begin // SPMM乘加
                        dma_instr_valid_o = 1'b0;
                        multi_cycle_instr = 1'b1;
                        vex_en = 1'b1;
                        sparse_load = 1'b0;
                        pe_op = PE_SPMM_COMPUTE;
                        operand_select = PE_OPERAND_CSR;//其中一个操作数来自CSR寄存器（稀疏矩阵数据）
                        if(compute_load_extra || compute_load_stationary) begin
                            vrf_load = 1'b1;
                        end else begin
                            vrf_load = 1'b0;
                        end
                        if(extra_load_num_ready_r) begin
                            dense_buf_read_en_o = 1'b1;
                            dense_buf_read_addr_o = dense_read_addr;
                            vrf_write = 1'b1;          //组合逻辑直接算完直接写入 不用vex回传一个信号
                        end else begin
                            dense_buf_read_en_o = 1'b0;
                            dense_buf_read_addr_o = '0;
                            vrf_write = 1'b0;          //组合逻辑直接算完直接写入 不用vex回传一个信号
                        end
                        if(dma_store_done) begin
                            dma_store_en <= 1'b0;
                            dma_max_data_cnt = 0;
                        end else begin
                            dma_store_en <= 1'b1;
                            dma_max_data_cnt = 35;
                        end
                    end
                    V_FUNCT6_LOAD: begin // SPMM Load
                        dma_instr_valid_o = 1'b0;
                        multi_cycle_instr = 1'b0;
                        load_index_o <= 1'b1; //让vex内部的buf读出一个index给vid
                        vex_en = 1'b1;
                        dense_buf_write_addr_o = vd_addr_r;
                        if(load_index_ready_r && scalar_operand_ready) begin     //ready之后在进入HOLD
                            vlsu_en_o = 1'b1;        //使能vlsu
                            vlsu_load_o = 1'b1;     //使能vlsu的load功能
                            dense_buf_write_en_o = 1'b0;   //使能dense buffer写入
                            pe_op = PE_SPMM_LOAD;
                            operand_select = PE_OPERAND_CSR; // 其中一个操作数来自CSR寄存器（稀疏矩阵数据）
                        end else begin 
                            vlsu_en_o = 1'b0;        //使能vlsu
                            vlsu_load_o = 1'b0;     //使能vlsu的load功能
                            dense_buf_write_en_o = 1'b0;
                            pe_op = PE_SPMM_LOAD;
                            operand_select = PE_OPERAND_CSR; 
                        end
                        if(dma_store_done) begin
                            dma_store_en <= 1'b0;
                            dma_max_data_cnt = 0;
                        end else begin
                            dma_store_en <= 1'b1;
                            dma_max_data_cnt = 35;
                        end
                    end
                    V_FUNCT6_STORE: begin
                        dma_instr_valid_o = 1'b0;
                        fix_vd_addr = 1'b1;                 // 固定目标地址
                        vlsu_en_o = 1'b1;
                        vlsu_store_o = 1'b0;
                        multi_cycle_instr = 1'b1;
                        dma_store_en = 1'b0; // 禁用DMA存储
                    end
                    V_FUNCT6_SPMM_LOAD: begin    //通过dma往buffer里存稀疏矩阵数据,最一开始执行一次，后面不再执行
                        multi_cycle_instr = 1'b1;
                        vex_en = 1'b0; // 不需要vex
                        dma_store_en = 1'b0;
                        if(dma_store_done) begin
                            dma_instr_valid_o = 1'b0;
                            dma_max_data_cnt = 0;
                        end else begin
                            dma_instr_valid_o = 1'b1; // 使能VLSU加载
                            dma_max_data_cnt = 35;
                        end
                    end
                    V_FUNCT6_ADD: begin
                        dma_instr_valid_o = 1'b0;
                        multi_cycle_instr = 1'b1;
                        vrf_write = 1'b0;
                        vex_en = 1'b1;            //这两句用来转exec到hold 并且vex数据输出到arith_output 
                        pe_op = PE_ARITH_ADD;     
                        vrf_load = 1'b1;    
                    end
                    V_FUNCT6_SPMM_LOAD_VECTOR: begin
                        pe_op = PE_SPMM_LOAD_VECTOR;
                        dma_instr_valid_o = 1'b0;
                        multi_cycle_instr = 1'b1;
                        pe_op = PE_SPMM_LOAD_VECTOR;
                        dense_buf_read_en_o_tag <= 1'b1;  //使能densebuf开始load 状态机从exec到hold阶段。
                    end
                    default: $error("unsupported SPMM instruction");
                endcase
            end
            default: $error("unrecognised major opcode");
        endcase
    end
  
  //hold下的组合逻辑控制
    if (state == HOLD) begin   //HOLD时保持enable
        case (opcode)
        V_OPCODE_SPMM:begin
            case(funct6)
            V_FUNCT6_CAL_INDEX : begin // 计算行索引
                dma_instr_valid_o = 1'b0;
                pe_op = PE_SPMM_CAL_INDEX;  
                operand_select = PE_OPERAND_CSR; 
                sparse_load = 1'b1; 
                sparse_write = 1'b0;
                vrf_load = 1'b0;          //trgger vrf start load data  ， write_en
                vrf_write = 1'b0;          //组合逻辑直接算完直接写入 不用vex回传一个信号
                vex_en = 1'b1;            //这两句用来转exec到hold
                dma_store_en = 1'b0;
                
            end
            V_FUNCT6_FIX_ROW : begin // 固定行
                dma_instr_valid_o = 1'b0;
                pe_op = PE_SPMM_FIX_ROW;  
                operand_select = PE_OPERAND_CSR; 
                sparse_load = 1'b0; 
                vlsu_en_o = 1'b1;
                sparse_write = 1'b0;
                vrf_load = 1'b0;          //trgger vrf start load data  ， write_en
                vex_en = 1'b0;            //这两句用来转exec到hold
                dma_store_en = 1'b0; // 禁用DMA存储
                if(vlsu_done_i && number_rows != 1) begin
                    vlsu_load_o <= 1'b1; //外部vlsu完成之后立马拉高vlsu的使能信号
                end else begin
                    vlsu_load_o <= 1'b0;
                end
            end
            V_FUNCT6_COMPUTE: begin 
                dma_instr_valid_o = 1'b0;
                pe_op = PE_SPMM_COMPUTE;
                operand_select = PE_OPERAND_CSR; 
                sparse_load = 1'b1; 
                sparse_write = 1'b0;
                vex_en = 1'b1;
                
                if(spmm_compute_done) begin
                    dense_buf_write_en_o = 1'b1;
                    dense_buf_write_addr_o = dense_write_addr;
                    vrf_write = 1'b1; 
                    vex_en = 1'b0;
                end else begin
                    vrf_write = 1'b0; 
                    dense_buf_write_en_o = 1'b0;
                    vex_en = vex_en;
                end
                if(compute_load_extra || compute_load_stationary) begin
                    vrf_load = 1'b1;
                end else begin
                    vrf_load = 1'b0;
                end
                if(extra_load_num_ready) begin
                    dense_buf_read_en_o <= 1'b1;
                    dense_buf_read_addr_o = dense_read_addr;
                    vrf_write = 1'b1;          //组合逻辑直接算完直接写入 不用vex回传一个信号
                end else begin
                    dense_buf_read_en_o <= 1'b0;
                    dense_buf_read_addr_o = '0;
                    vrf_write = 1'b0;          //组合逻辑直接算完直接写入 不用vex回传一个信号
                end
                if(dma_store_done) begin
                    dma_store_en <= 1'b0;
                    dma_max_data_cnt = 0;
                end else begin
                    dma_store_en <= 1'b1;
                    dma_max_data_cnt = 35;
                end
            end
            V_FUNCT6_LOAD: begin //spmm load
                dma_instr_valid_o = 1'b0;
                vex_en = 1'b1;  //拉高vex需要他去计算 不需要用到cycle_cnt 结束根据vlsu_done_i
                sparse_write = 1'b0;
                vrf_load = 1'b0; 
                load_index_o = 1'b1;
                dense_buf_read_en_o = '0;
                sparse_load = 1'b1;
                dense_buf_write_addr_o = vd_addr_r;
                pe_op = PE_SPMM_LOAD; // SPMM加载操作
                operand_select = PE_OPERAND_CSR; // 其中一个操作数来自CSR寄存器
                dma_store_en <= 1'b0;
                if(vlsu_done_i) begin
                    vlsu_load_o <= 1'b1; //外部vlsu完成之后立马拉高vlsu的使能信号
                    dense_buf_write_en_o = 1'b1;   //使能dense buffer写入
                end else begin
                    vlsu_load_o <= 1'b0;
                    dense_buf_write_en_o = 1'b0;
                end
            end
            V_FUNCT6_STORE: begin
                dense_buf_read_en_o = 1'b1;
                dense_buf_read_addr_o = rd + OFFSET_TEMP_MATRIX;
                dma_instr_valid_o = 1'b0;
                vlsu_store_o = 1'b1; // 继续存储操作
                dma_store_en = 1'b0;
             end
            V_FUNCT6_SPMM_LOAD: begin
                dma_store_en  = 1'b0; // 禁用DMA存储
                if(dma_store_done) begin
                    dma_instr_valid_o = 1'b0;
                    dma_max_data_cnt = 0;
                end else begin
                    dma_instr_valid_o = 1'b1; // 使能VLSU加载
                    dma_max_data_cnt = 35;
                end
            end
            V_FUNCT6_SPMM_LOAD_VECTOR:begin
                dma_instr_valid_o = 1'b0;
                pe_op = PE_SPMM_LOAD_VECTOR;
                dense_buf_read_en_o <= 1'b1; //hold状态下拉高dense buffer读
                if(load_vector_count < 3'b011) begin 
                    dense_buf_read_addr_o <= rd + OFFSET_FLEXIBLE_MATRIX + OFFSET_MATRIX * load_vector_count;
                end
                else dense_buf_read_addr_o <= '0;
            end
            V_FUNCT6_ADD: begin // fixme
                dma_instr_valid_o = 1'b0;
                multi_cycle_instr = 1'b1;  
                if (funct3 == '0) begin // 
                dense_buf_write_en_o = 1'b1;
                dense_buf_write_addr_o = OFFSET_TEMP_MATRIX + rd;  //加完直接放到densebuf里的temp result区域。rd是矩阵的第n行，前面的是固定偏移地址
                vrf_write = 1'b0;
                end else begin   //当funct3 == 3'b001的时候使能vrf_write
                dense_buf_write_en_o = 1'b0;
                vrf_write = 1'b1;  //hold阶段再开始写
                end
                vex_en = 1'b1;            
                pe_op = PE_ARITH_ADD;     
                vrf_load = 1'b1;          
            end
            endcase
        end
        endcase
    end
    if(state == BUS_HOLD) begin
        vex_en = 1'b0;
        dma_instr_valid_o = 1'b0;
        pe_op = PE_SPMM_COMPUTE;
        operand_select = PE_OPERAND_CSR; 
        sparse_load = 1'b1; 
        sparse_write = 1'b0;
        vrf_load = 1'b1; 
        dma_store_en = 1'b0; // 禁用DMA存储
        vrf_write = 1'b0; 
    end
end

always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        dense_index_reg <= '0;
    end else begin
        if(state == HOLD && opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_CAL_INDEX) begin
            dense_index_reg <= row_index_dense_i;
        end else begin
            dense_index_reg <= dense_index_reg;
        end
    end
end
//新增
logic [4:0] extra_load_num_reg;//存储compute的时候需要从dense_buffer里拿几个数据出来
logic extra_load_num_ready;
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        extra_load_num_reg <= '0;
        extra_load_num_ready <= 1'b0;
    end else begin
        if(extra_load_done && opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_COMPUTE) begin
            extra_load_num_ready <= 1'b0;
            extra_load_num_reg <= extra_load_num_reg;
        end else if(opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_COMPUTE && !extra_load_done) begin
            extra_load_num_reg <= extra_load_num_i;
            extra_load_num_ready <= 1'b1;
        end else if(opcode == V_OPCODE_SPMM && funct6 == V_FUNCT6_COMPUTE) begin
            extra_load_num_ready <= extra_load_num_ready;
            extra_load_num_reg <= extra_load_num_reg;
        end else begin
            extra_load_num_reg <= extra_load_num_reg;
            extra_load_num_ready <= 1'b0;
        end
    end
end

logic extra_load_num_ready_r;
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        extra_load_num_ready_r <= '0;
    end else begin
        extra_load_num_ready_r <= extra_load_num_ready;
    end
end
//设置一个计数器，让dense buffer读出对应数量的数据
logic [4:0] dense_buf_read_count;
logic extra_load_valid;
logic extra_load_done;
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        dense_buf_read_count <= '0;
        extra_load_done <= '0;
    end else begin
        if(pe_op == PE_SPMM_COMPUTE && compute_row_data_num == '0) begin
            extra_load_valid <= '1;
            extra_load_done <= 1'b1;    
        end
        if(pe_op == PE_SPMM_COMPUTE && extra_load_num_ready) begin
            if(dense_buf_read_count == (extra_load_num_reg)) begin
                dense_buf_read_count <= '0;
                extra_load_valid <= 1'b0;
                extra_load_done <= 1'b1;
            end else if(dense_buf_read_count <= (extra_load_num_reg - 1) && !extra_load_done) begin
                dense_buf_read_count <= dense_buf_read_count + 1'b1;
                extra_load_valid <= 1'b1;
                extra_load_done <= 1'b0;
            end
        end else begin
            dense_buf_read_count <= '0;
            extra_load_valid <= 1'b0;
            extra_load_done <= 1'b0;
        end
    end
end

always_comb begin
    if(opcode == V_OPCODE_SPMM && funct6 == (V_FUNCT6_COMPUTE)) begin
        bus_spare = 1'b1;
    end else begin
        bus_spare = 1'b0;
    end
end


endmodule