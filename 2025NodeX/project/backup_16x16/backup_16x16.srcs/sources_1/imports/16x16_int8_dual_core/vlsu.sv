
import rvv_pkg::*;

// 待解决问题：stride从哪来，如果是跨步访问，应当自己设置或由vsew和vlmul设置
// 如果固定地址也要从decoder中获取
module vlsu (
    input  wire         clk,             
    input  wire         rstn,         
    // Vector CSR（控制状态寄存器）输入
    input  wire [7:0]   vl,            // 向量长度，表示处理的元素数量
    input  wire [1:0]   vsew_i,          // 向量元素宽度（00: 8位, 01: 16位, 10: 32位）

    // VLSU解码控制信号
    input  wire         vlsu_en_i,       // VLSU使能信号
    input  wire         vlsu_load_i,     // 向量加载操作使能
    input  wire         vlsu_store_i,    // 向量存储操作使能
    input  wire         vlsu_strided_i,  // 是否为跨步（strided）访问
    output logic        vlsu_ready_o,    // VLSU准备好信号
    output logic        vlsu_done_o,     // VLSU操作完成信号
    output logic        cycle_done, // VLSU加载完成信号 

    // 对外部存储
    output logic        data_req_o,      // 数据请求信号
    input  logic        data_gnt_i,      // 数据授权信号
    input  logic        data_rvalid_i,   // 数据读有效信号
    output logic [31:0] data_addr_o,     // 数据地址
    output logic        data_we_o,       // 数据写使能
    output logic [3:0]  data_be_o,       // 字节使能信号（控制32位字中的字节访问）
    input  logic [31:0] data_rdata_i,    // 内存读取数据
    output logic [31:0] data_wdata_o,    // 内存写入数据

    // decode输入
    input  wire [31:0]  addr_data_i,     // 加载的源地址/存储的目标地址
    input  wire [11:0]  stride_data_i,   // 跨步访问的步幅值
    input  wire         reduction,       // 是否为归约操作

    // vrf接口 && densebuff接口
    input  logic [4:0]   vr_addr_i,      // decode输出的vd_addr，如果为VS3_ADDR_SRC_DECODE则成为vs3_addr
    input  logic [127:0] vs_rdata_i,     // 从矢量寄存器读取的数据（vs3 data）
    output logic [127:0] vs_wdata_o,     // 写回矢量寄存器的数据（128位宽）
    output logic [4:0]   vs3_addr_o,     // vs3_addr_vlsu，如果为VS3_ADDR_SRC_VLSU则成为vs3_addr
    output logic         vr_we_o         // 向量寄存器写使能  todo:跟vlsu done一样？

);

// 内部信号声明
logic        au_start;                   // temporary_reg 启动信号
logic [3:0]  au_be;                      // 地址单元字节使能，控制每次内存访问的字节
logic [7:0]  vd_offset;                  // 向量数据偏移量，计算写入矢量寄存器的字节位置
//logic cycle_done;                        // 加载周期完成信号

// 计数与控制信号
logic signed [7:0] byte_track;          // 当前剩余字节计数
logic signed [7:0] byte_track_next;     // 下一状态的字节计数
logic cycle_load;                       // 加载周期控制信号，表示正在加载
logic cycle_addr_inc;                   // 地址递增控制信号，表示地址更新
logic store_cycles_inc;                 // 存储周期递增控制信号
logic [3:0] store_cycle_be;             // 存储操作的字节使能
logic [2:0] store_cycles;               // 存储操作的总周期数
logic [2:0] store_cycles_cnt;           // 存储周期计数器
logic [2:0] load_cycles_cnt;           // 存储周期计数器
logic [31:0] data_rdata_r;

always_ff @(posedge clk or negedge rstn) begin
    if(!rstn) begin
        data_rdata_r <= '0;
    end else begin
        data_rdata_r <= data_rdata_i;
    end
end

// 临时寄存器模块实例化，用于处理加载数据的字节对齐和存储
temporary_reg tr (
    .clk_i              (clk),           // 时钟输入
    .rstn               (rstn),          // 复位输入
    .byte_enable_valid  (data_req_o),    // 字节使能有效信号，与数据请求同步
    .read_data_valid    (cycle_addr_inc), // 读取数据有效信号   todo： 或改成data_rvalid_i
    .clear_register     (au_start | cycle_done),      // 清空寄存器信号，与地址单元启动同步
    .memory_read_i      (data_rdata_r),  // 从内存读取的数据
    .byte_enable_i      (au_be),         // 字节使能输入
    .byte_select_i      (vd_offset), // 字节选择偏移量
    .wide_vd_o          (vs_wdata_o),    // 输出到宽向量寄存器的数据
    .load_cycles_done   (cycle_done)     // 加载周期完成信号
);


// 数据write逻辑：根据vsew从向量寄存器中选择数据并格式化为32位输出
// 此模块已修改，目前只支持gemv输出
always_comb begin
    data_wdata_o = 'd0;                  // 默认清零
    case(vsew_i)
        2'd0 : begin                     // 8位元素，从128位数据中提取4个字节
            case (store_cycles_cnt) 
                3'd0 : data_wdata_o = {vs_rdata_i[31:0]};
                3'd1 : data_wdata_o = {vs_rdata_i[63:32]};
                3'd2 : data_wdata_o = {vs_rdata_i[95:64]};
                3'd3 : data_wdata_o = {vs_rdata_i[127:96]};
                default: data_wdata_o = '0; // 无效宽度，默认清零
            endcase
        end
        2'd1 : begin                     // 16位元素，根据地址选择两个16位数据
            case(store_cycles_cnt)
                3'd0 : data_wdata_o = {vs_rdata_i[31:0]};
                3'd1 : data_wdata_o = {vs_rdata_i[63:32]};
                3'd2 : data_wdata_o = {vs_rdata_i[95:64]};
                3'd3 : data_wdata_o = {vs_rdata_i[127:96]};
                default: data_wdata_o = '0; // 无效宽度，默认清零
            endcase
        end
        2'd2 : begin                     // 32位元素
            case(store_cycles_cnt) 
                3'd0 : data_wdata_o = {vs_rdata_i[31:0]};
                3'd1 : data_wdata_o = {vs_rdata_i[63:32]};
                3'd2 : data_wdata_o = {vs_rdata_i[95:64]};
                3'd3 : data_wdata_o = {vs_rdata_i[127:96]};
                default: data_wdata_o = '0; // 无效宽度，默认清零
            endcase
        end
        default: data_wdata_o = '0;      // 无效宽度，默认清零
    endcase
end

// 地址与数据处理信号
logic [1:0]  ib_select;                 // 初始地址低2位，用于字节选择
logic [3:0]  be_gen;                    // 字节使能生成信号
logic [31:0] next_el_pre;               // 下一个元素的预计算地址
logic [31:0] next_el_addr;              // 下一个元素的最终地址
logic [31:0] cycle_addr;                // 当前周期的内存地址
logic [9:0]  stride;                    // 步幅值，控制地址递增
logic [6:0]  cycle_bytes;               // 当前周期处理的字节数


// 状态机定义
typedef enum logic [2:0] {
    RESET       = 3'd0, // 复位状态，等待操作请求
    LOAD_FIRST  = 3'd1, // 加载初始状态，准备加载
    LOAD_CYCLE  = 3'd2, // 加载循环状态，发起内存请求
    LOAD_WAIT   = 3'd3, // 加载等待状态，等待内存响应
    LOAD_FINAL  = 3'd4, // 加载完成状态，写回数据
    STORE_CYCLE = 3'd5, // 存储循环状态，发起写请求
    STORE_WAIT  = 3'd6, // 存储等待状态，等待内存确认
    STORE_FINAL = 3'd7  // 存储完成状态，结束操作
} be_state;
be_state current_state;                 // 当前状态
be_state next_state;                    // 下一状态



// 步幅和地址计算
// 如果跨步访问，使用stride_data_i，否则根据元素宽度计算步幅
// vsew_i = 2'b00：8位，32'd1 << 0 = 1；2'b01：16位，32'd1 << 1 = 2
assign stride = vlsu_strided_i ? stride_data_i : (32'd1 << vsew_i);      

// store_cycles_cnt 是存储周期计数器，每次存储32位（4字节），<< 2 相当于乘以4
// 存储地址递增，基地址加上存储周期的偏移量，确保每次存储操作写入新的4字节对齐地址
// 加载地址在每次循环中通过状态机更新（cycle_addr_inc），不直接依赖计数器，基地址强制对齐到4字节边界
assign data_addr_o = vlsu_store_i ? ({cycle_addr[31:2], 2'b00} + (store_cycles_cnt << 2)) :      
                     {cycle_addr[31:0]} ; 



assign au_be = be_gen;    // 地址单元字节使能来自生成信号

// 元素数量 * 宽度 = 字节数，byte_track为剩余待处理的字节数
// 计算向量数据偏移量，表示当前数据应写入的字节位置
assign vd_offset = (vl << vsew_i) - byte_track;   

// 存储操作的字节使能生成
always_comb begin
    if(byte_track >= 4)                  // 如果剩余字节数大于等于4
        store_cycle_be = 4'b1111;        // 4字节全使能
    else if(byte_track >= 3)
        store_cycle_be = 4'b0111;        // 使能3字节
    else if(byte_track >= 2)
        store_cycle_be = 4'b0011;
    else
        store_cycle_be = 4'b0001;

    data_be_o = vlsu_store_i ? store_cycle_be : 4'b1111; // 存储时使用动态字节使能，加载时全使能
end 

// 字节跟踪逻辑，计算剩余字节数
always_comb begin
    if(au_start)
        byte_track_next = (vl << vsew_i); // 初始化为总字节数（元素数 * 元素宽度）
    else if(cycle_addr_inc)
        byte_track_next = (byte_track >= cycle_bytes) ? (byte_track - cycle_bytes) : 7'd0; // 每次加载减少处理的字节数，到0即为完成
    else if(store_cycles_inc)
        byte_track_next = byte_track - 4; // 存储时每次减少4字节
    else 
        byte_track_next = byte_track;    // 保持不变
end 


logic [1:0]vlsu_load;                   // 加载使能信号，延长load信号周期
always_ff @(posedge clk or negedge rstn) begin
    if(!rstn)
    vlsu_load <= 1'b0;                 // 默认不加载
    else begin
        if (vlsu_load_i)
            vlsu_load[0] <= 1'b1;          // 加载使能
        else
            vlsu_load[0] <= 1'b0;          // 加载完成后清零
        if (vlsu_load[0])
            vlsu_load[1] <= 1'b1;          // 加载使能
        else
            vlsu_load[1] <= 1'b0;
    end
end    

// 拉长数据读取有效信号，使状态机可工作
logic [1:0]data_rvalid;
always_ff @(posedge clk or negedge rstn) begin
    if(!rstn)
    data_rvalid <= 2'b00;                 // 默认不加载
    else begin
        if (data_rvalid_i)
            data_rvalid[0] <= 1'b1;          // 加载使能
        else
            data_rvalid[0] <= 1'b0;          // 加载完成后清零
        if (data_rvalid[0])
            data_rvalid[1] <= 1'b1;          // 加载使能
        else
            data_rvalid[1] <= 1'b0;
    end
end  

// 寄存器更新：状态、地址和计数器
always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        current_state <= RESET;          // 复位到初始状态
        byte_track <= 8'd0;              // 复位清零字节计数
        cycle_addr <= 32'd0;             // 复位清零地址
        store_cycles_cnt <= 2'd0;        // 复位清零存储周期计数器
        load_cycles_cnt <= 2'd0;        // 复位清零存储周期计数器
    end else begin
        current_state <= next_state;     // 更新状态
        byte_track <= byte_track_next;   // 更新字节计数

        // 地址更新逻辑
        if (au_start)
            cycle_addr <= addr_data_i;   // 使用基地址初始化
        else if (cycle_addr_inc)
            cycle_addr <= next_el_addr;  // 更新到下一地址
        //else if (store_cycles_inc)
        //    cycle_addr <= next_el_addr; // 更新到下一地址
        else 
            cycle_addr <= cycle_addr; // 保持不变

        // load/store周期计数器更新逻辑
        if (au_start) begin
            load_cycles_cnt <= 2'd0;       // 复位清零load周期计数器
            store_cycles_cnt <= 2'd0;    // 操作开始时清零
        end
        else if (cycle_addr_inc)            // 如果load地址递增
            load_cycles_cnt <= load_cycles_cnt + 2'd1; // 存储周期递增
        else if (store_cycles_inc)
            store_cycles_cnt <= store_cycles_cnt + 2'd1; // 存储周期递增
    end
end

// 存储周期数计算
assign store_cycles =((vl >> (2 - vsew_i)) + 1); // 计算存储周期数，元素数量/每周期存储的元素数+1
// 若 vl = 5，vsew_i = 2'b01(16位)，则 5 >> 1 = 2，store_cycles = 2 + 1 = 3
assign vs3_addr_o = vr_addr_i + store_cycles_cnt; // 基地址+周期，存储周期递增，源寄存器地址逐步偏移

// 字节使能和地址生成逻辑
always_comb begin
    be_gen = 4'b0000;                    // 默认字节使能清零
    next_el_pre = '0;                    // 下一个元素预地址清零
    cycle_bytes = '0;                    // 当前周期字节数清零
    ib_select = '0;                      // 初始字节选择清零
    next_el_addr = '0;                   // 下一个元素地址清零

    case(vsew_i)
        2'b00 : begin                    // 8位元素
            ib_select = cycle_addr[1:0]; // 初始地址低2位，决定当前处理的字节位置（0、1、2 或 3）
            if(stride > 10'd1) begin     // 跨步大于1
                be_gen[ib_select] = 1'b1;// 使能当前字节
                next_el_pre = cycle_addr + stride; // 计算下一个元素地址
                if(next_el_pre[31:2] == cycle_addr[31:2] && byte_track > 1) begin
                    be_gen[next_el_pre[1:0]] = 1'b1; // 如果在同一4字节边界内，且 byte_track > 1（剩余字节数足够），使能下一个字节
                    next_el_addr = next_el_pre + stride; // 跨步到第二个元素
                end else begin
                    next_el_addr = next_el_pre; // 使用预地址
                end
                /*示例：若 cycle_addr = 0x1000，stride = 2，ib_select = 0，byte_track = 4：
                be_gen[0] = 1，next_el_pre = 0x1002。
                0x1002[31:2] == 0x1000[31:2]，be_gen[2] = 1，next_el_addr = 0x1004。
                cycle_bytes = 2。*/

                cycle_bytes = {5'd0, be_gen[3]} + {5'd0, be_gen[2]} + {5'd0, be_gen[1]} + {5'd0, be_gen[0]}; // 计算处理的字节数

            end else if(stride == 1) begin // 连续访问
                if (ib_select == 2'b00) begin
                    be_gen[0] = ( byte_track >= 1) ? 1'b1 : 1'b0;       // (ib_select == 2'd0) ? 1 : 0;
                    be_gen[1] = ( byte_track >= 2) ? 1'b1 : 1'b0;
                    be_gen[2] = ( byte_track >= 3) ? 1'b1 : 1'b0;
                    be_gen[3] = ( byte_track >= 4) ? 1'b1 : 1'b0;
                end else begin
                    be_gen[0] = 1'b0;       // (ib_select == 2'd0) ? 1 : 0;
                    be_gen[1] = (ib_select <= 1 ) ? 1'b1 : 1'b0;
                    be_gen[2] = (ib_select <= 2 ) ? 1'b1 : 1'b0;
                    be_gen[3] = (ib_select <= 3 ) ? 1'b1 : 1'b0;
                end

                next_el_addr = {cycle_addr[31:2], 2'b0} + 32'd4; // 跳转到下一4字节边界
               
                cycle_bytes = {5'd0, be_gen[3]} + {5'd0, be_gen[2]} + {5'd0, be_gen[1]} + {5'd0, be_gen[0]}; // 计算字节数
          
            end else if(stride == 10'd0) begin // 零步幅（重复读取）
                be_gen[ib_select] = 1'b1;
               
                cycle_bytes = vl; // 一次性读取所有字节
        
            end
            // todo：需要defult
        end
        2'b01 : begin                    // 16位元素
            ib_select = {cycle_addr[1], 1'b0}; // 强制对齐到0或2字节
            if(stride > 10'd2) begin     // 跨步大于2
                be_gen[ib_select] = 1'b1;   
                be_gen[ib_select+1] = 1'b1; // 使能2字节
                next_el_addr = {cycle_addr[31:1], 1'b0} + {stride[9:1], 1'b0}; // 对齐计算下一地址
               
                cycle_bytes = {5'd0, be_gen[3]} + {5'd0, be_gen[2]} + {5'd0, be_gen[1]} + {5'd0, be_gen[0]};
        
            end else if (stride == 10'd2) begin // 连续16位元素
                be_gen[1:0] = (ib_select == 0) ? 2'b11 : 2'b00;
                be_gen[3:2] = (ib_select == 2 || byte_track > 2) ? 2'b11 : 2'b00;
                next_el_addr = {cycle_addr[31:2], 2'b0} + 32'd4; // 下一4字节边界
              
                cycle_bytes = {5'd0, be_gen[3]} + {5'd0, be_gen[2]} + {5'd0, be_gen[1]} + {5'd0, be_gen[0]};
           
            end else if (stride == 10'd0) begin // 零步幅
                be_gen[ib_select] = 1'b1;
                be_gen[ib_select+1] = 1'b1;
         
                cycle_bytes = {vl}; // 读取所有字节
         
            end
        end
        2'b10 : begin                    // 32位元素
            ib_select = 2'd0;            // 强制对齐到0字节
            if(stride > 12'd4) begin    // 跨步大于等于4
                be_gen = 4'b1111;        // 全使能
                next_el_addr = {cycle_addr[31:2], 2'b0} + {stride[9:2], 2'b0}; // 对齐下一地址
             
                cycle_bytes = {5'd0, be_gen[3]} + {5'd0, be_gen[2]} + {5'd0, be_gen[1]} + {5'd0, be_gen[0]};
           
            end else if (stride == 10'd4) begin // 连续16位元素
                be_gen[3:0] = (ib_select == 0) ? 4'b1111 : 4'b0000;
                next_el_addr = {cycle_addr[31:2], 2'b0} + 32'd4; // 下一4字节边界              
                cycle_bytes = {5'd0, be_gen[3]} + {5'd0, be_gen[2]} + {5'd0, be_gen[1]} + {5'd0, be_gen[0]};

            end else if(stride == 10'd0) begin // 零步幅
                be_gen = 4'b1111;
           
                cycle_bytes = {vl}; // 读取所有字节
           
            end
        end
        default : $error("Invalid VSEW"); // 无效的元素宽度，报错
    endcase
end

// 状态机控制逻辑
always_comb begin
    cycle_load = 1'b0;                   // 默认不启用加载周期
    data_req_o = 1'b0;                   // 默认无数据请求
    data_we_o = 1'b0;                    // 默认无写使能
    au_start = 1'b0;                     // 默认不启动地址单元
    vlsu_done_o = 1'b0;                  // 默认未完成
    vlsu_ready_o = 1'b0;                 // 默认未准备好
    cycle_addr_inc = 1'b0;               // 默认不递增地址
    store_cycles_inc = 1'b0;             // 默认不递增存储周期
    vr_we_o = 1'b0;                      // 默认不写向量寄存器
    next_state = current_state;          // 默认保持当前状态
    
    case(current_state)
        RESET: begin                     // 复位状态
            vlsu_ready_o = 1'b1;         // 表示VLSU准备好接受操作
            if(vlsu_load[0]) begin        // 如果请求加载
                au_start = 1'b1;         // 启动地址单元
                next_state = LOAD_CYCLE; // 进入加载初始状态
            end else if (vlsu_store_i) begin // 如果请求存储
                au_start = 1'b1;
                next_state = STORE_CYCLE;// 进入存储周期状态
            end else begin
                next_state = RESET;      // 保持复位状态
            end
        end
//        LOAD_FIRST: begin                // 加载初始状态
//            next_state = LOAD_CYCLE;     // 进入加载循环状态
//        end
        LOAD_CYCLE: begin                // 加载循环状态
            if(byte_track_next == 0) begin // 如果所有字节加载完成  ,当vl为4倍数时，最后一个应该是1?
                next_state = LOAD_FINAL;  // 进入等待状态
            end else begin
                data_req_o = 1'b1;       // 发起数据请求
                cycle_load = 1'b1;       // 表示正在加载
                next_state = LOAD_WAIT;  // 等待内存响应
            end
        end
        LOAD_WAIT: begin                 // 加载等待状态
            if(data_rvalid[1] | data_rvalid[0]) begin      // 如果内存数据有效
                cycle_addr_inc = 1'b1;   // 更新地址
                next_state = LOAD_CYCLE; // 返回加载循环
            end 
            else
                next_state = LOAD_WAIT;  // 继续等待
        end
        LOAD_FINAL: begin                // 加载完成状态
            next_state = RESET;          // 返回复位状态
            vlsu_done_o = 1'b1;          // 表示操作完成
            vlsu_ready_o = 1'b1;         // 表示VLSU准备好接受操作
            vr_we_o = 1'b1;              // 写回向量寄存器
        end
        STORE_CYCLE: begin               // 存储循环状态
            if(byte_track_next == 0) begin
                next_state = STORE_FINAL;  
            end else begin
            data_req_o = 1'b1;           // 发起数据请求
            data_we_o = 1'b1;            // 使能写操作
            next_state = STORE_WAIT;     // 进入存储等待状态
            end
        end
        STORE_WAIT: begin                // 存储等待状态
            if(data_rvalid[1] | data_rvalid[0]) begin      // 如果内存响应有效
                if(store_cycles_cnt == store_cycles-1) begin // 如果所有周期完成（或 store_cycles-1）
                    next_state = STORE_FINAL; // 进入存储完成状态
                end else begin 
                    store_cycles_inc = 1'b1; // 递增存储周期
                    next_state = STORE_CYCLE;// 返回存储循环
                end
            end else begin
                next_state = STORE_WAIT; // 继续等待
            end
        end
        STORE_FINAL: begin               // 存储完成状态
            vlsu_done_o = 1'b1;          // 表示操作完成
            vlsu_ready_o = 1'b1;         // 表示VLSU准备好接受操作
            next_state = RESET;          // 返回复位状态
        end
    endcase
end

endmodule

////////////////////////////////////////////////

// 32-Bit input, byte_position selects the bytes to load.
// Selected bytes will be packed and loaded into the 
// register starting from byte_loaded

// Temporary Register Module: 处理加载数据的字节对齐和打包
module temporary_reg (
    input  logic        clk_i,           
    input  logic        rstn,         
    input  logic        byte_enable_valid, // 字节使能有效信号
    input  logic        read_data_valid,   // 读取数据有效信号
    input  logic        clear_register,    // 清空寄存器信号
    input  logic [31:0] memory_read_i,     // 从内存读取的32位数据
    input  logic [3:0]  byte_enable_i,     // 字节使能输入，每位指示一个字节是否加载
    input  logic [7:0]  byte_select_i,     // 字节选择偏移量，指定 temp_reg 的写入起始位置
    output logic [127:0] wide_vd_o,        // 128位输出到向量寄存器
    output logic load_cycles_done          // 加载周期完成信号
);

    logic [3:0] byte_enable_reg;         // 存储字节使能信号的寄存器

    // 在有效请求时存储字节使能信号
    always_ff @(posedge clk_i or negedge rstn) begin
        if (!rstn) begin
            byte_enable_reg <= 4'b0000;  
        end 
        else if (byte_enable_valid) begin
            byte_enable_reg <= byte_enable_i; 
        end
    end

    always_comb begin
        if (((byte_select_i[3:0] >= 4'b0000) 
        & (byte_select_i[3:0] < 4'b0100)) 
        & (byte_select_i != 8'b0)
        & byte_enable_valid) 
        begin
            load_cycles_done <= 1'b1;
        end
        else 
            load_cycles_done <= 1'b0;
    end


    // 临时寄存器，分为16个字节（共128位）
    logic [7:0] temp_reg [15:0];

    // 将32位内存数据拆分为字节
    logic [7:0] memory_read_bytes [3:0];
    always_comb begin
        memory_read_bytes[0] = memory_read_i[7:0];
        memory_read_bytes[1] = memory_read_i[15:8];
        memory_read_bytes[2] = memory_read_i[23:16];
        memory_read_bytes[3] = memory_read_i[31:24];
    end

    // 打包启用的字节到连续位置
    logic [7:0] memory_read_packed [3:0]; // 打包后的字节数组
    logic [3:0] packed_set;               // 跟踪已打包的字节位置

    always_comb begin
        memory_read_packed = '{default: 8'd0}; // 默认清零
        packed_set = 4'b0000;         
        if (byte_enable_reg[0]) begin     // 如果第 0 个字节启用
            packed_set[0] = 1'b1;
            memory_read_packed[0] = memory_read_bytes[0];
        end
        if (byte_enable_reg[1]) begin     // 如果第 1 个字节启用
            casez (packed_set)
                4'b???0: begin            // 如果位置 0 为空，放入位置 0
                    packed_set[0] = 1'b1;
                    memory_read_packed[0] = memory_read_bytes[1];
                end
                4'b???1: begin            // 如果位置 0 已占用，放入位置 1
                    packed_set[1] = 1'b1;
                    memory_read_packed[1] = memory_read_bytes[1];
                end
            endcase
        end
        if (byte_enable_reg[2]) begin
            casez (packed_set)
                4'b??00: begin          // 放入位置0
                    packed_set[0] = 1'b1;
                    memory_read_packed[0] = memory_read_bytes[2];
                end
                4'b??01: begin          // 放入位置1
                    packed_set[1] = 1'b1;
                    memory_read_packed[1] = memory_read_bytes[2];
                end
                4'b??11: begin          // 放入位置2
                    packed_set[2] = 1'b1;
                    memory_read_packed[2] = memory_read_bytes[2];
                end
            endcase
        end
        if (byte_enable_reg[3]) begin
            casez (packed_set)
                4'b?000: begin          // 放入位置0
                    packed_set[0] = 1'b1;
                    memory_read_packed[0] = memory_read_bytes[3];
                end
                4'b?001: begin          // 放入位置1
                    packed_set[1] = 1'b1;
                    memory_read_packed[1] = memory_read_bytes[3];
                end
                4'b?011: begin          // 放入位置2
                    packed_set[2] = 1'b1;
                    memory_read_packed[2] = memory_read_bytes[3];
                end
                4'b?111: begin          // 放入位置3
                    packed_set[3] = 1'b1;
                    memory_read_packed[3] = memory_read_bytes[3];
                end
            endcase
        end
    end

    // 将打包后的字节写入临时寄存器
    always_ff @(posedge clk_i or negedge rstn) begin
        if (!rstn) begin
            temp_reg <= '{default: 8'd0};
        end else if (clear_register) begin
            temp_reg <= '{default: 8'd0};       // 操作开始时清零
        end else if (read_data_valid) begin     // 当读取数据有效时写入
            if (packed_set[0]) temp_reg[byte_select_i[3:0] + 0] <= memory_read_packed[0];
            if (packed_set[1]) temp_reg[byte_select_i[3:0] + 1] <= memory_read_packed[1];
            if (packed_set[2]) temp_reg[byte_select_i[3:0] + 2] <= memory_read_packed[2];
            if (packed_set[3]) temp_reg[byte_select_i[3:0] + 3] <= memory_read_packed[3];
        end
    end

    // 组合临时寄存器的字节为128位输出
    assign wide_vd_o = {temp_reg[15], temp_reg[14], temp_reg[13], temp_reg[12],
                       temp_reg[11], temp_reg[10], temp_reg[9], temp_reg[8],
                       temp_reg[7], temp_reg[6], temp_reg[5], temp_reg[4],
                       temp_reg[3], temp_reg[2], temp_reg[1], temp_reg[0]};
endmodule


// 周期:           0          1          2          3          4         5
// clk:            _/‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾\
// rstn:           1          1          1         1         1         1
// vlsu_load_i:    0          1          0         0         0         0
// current_state:  RESET   LOAD_CYCLE  LOAD_WAIT LOAD_CYCLE LOAD_WAIT LOAD_FINAL
// data_req_o:     0          1          0         1         0         0
// data_rvalid_i:  0          0          1         0         1         0
// data_addr_o:    -          0x1000     -         0x1004    -         -
// byte_track:     -          8          8         4         4         0
// vs_wdata_o:     -          -          -         [63:0]    [127:64]  [127:0]
// vr_we_o:        0          0          0         0         0         1
// vlsu_done_o:    0          0          0         0         0         1