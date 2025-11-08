// 引入 RISC-V Vector 扩展相关的包定义
import rvv_pkg::*;

// vex 模块
// 功能：向量执行单元，在load指令下进行row_index的计算，在compute指令下进行spmm计算
// 现在支持load和计算完第一个矩阵的四行数据之后继续计算第二个矩阵了，用了两个计数器来控制各个指针的初始化

//原先是4个lane int32 4x4    输出都是128bit
//现在改为16和lane int8 16x16
module vex #(
    parameter LANES = 16,
    parameter DATA_WIDTH = 8,
    parameter ROW_STATIONARY_NUM = 4 //常用行的数量
) (
    output logic [LANES*DATA_WIDTH-1:0] arith_output,//输出spmm最终算出来的一行数据
    output logic [3:0] hold_req_o,
    output logic comp_done,//计算完成标志                                                                         
    
    input  wire clk,
    input  wire rstn,
    input  wire vex_en,
    input  wire vrf_load,
    input  wire vrf_write,

 
    input  wire [LANES*DATA_WIDTH-1:0] vs1_data_i,  //一次输入数据是128bit  来自与vrf 
    input  wire [LANES*DATA_WIDTH-1:0] vs2_data_i,//输入的dense matrix数据
    input  wire [31:0] scalar_operand,
    input  wire [4:0] imm_operand,
    input  wire [3:0] cycle_count,
    input  wire [3:0] max_cycle_cnt,    // 最大加载计数（用于加载数据）
    input  wire [3:0] op,
    input  wire [1:0] operand_select,
    input  wire [7:0] vl,
    input  wire [1:0] vsew,
    input  wire       nib_hold_i,
 
    input  wire [31:0] csr_data_i,
    //vex -- vrf spmm
    output wire [15:0] row_index,// 代表15行，哪个位置拉高则需要哪一行，index[0]为1则说明需要需要第0行的数据
    output wire addr_ready, // row_index准备好了

    //vex -- vid spmm 
    input  wire csr_load,//载入稀疏矩阵数据
    input  wire csr_write,
    output wire spmm_compute_done,//计算完成发出的标志信号
    input  wire spmm_load_done,//vid发出的加载完成信号
    input  wire load_row_index_i,
    output logic [4:0] compute_row_data_num,
    output logic index_ready,
    output logic index_cal_done, // index计算完成信号
    output logic [3:0] compute_rows_id [8],
    output logic [3:0] extra_rows_id [8],

    //vex -- vid index
    output logic cal_stationary_done,
    output logic [15:0] row_index_dense, //代表这四个常用行分别是dense matrix的哪几行
    output logic [4:0] extra_load_num_o, // 当前常用行的数量 新增
    output logic [3:0] sorted_top_rows [4],


    //vex -- sparse_buf
    output logic buf_load_en, //从buffer load稀疏矩阵数据进来
    input  logic buf_data_ready,
    input  logic dma_store_done // dma存储完成信号
);

    // 本地参数计算  
    localparam DEPTH = $clog2(LANES);
    localparam VEX_WIDTH = LANES * DATA_WIDTH;
    localparam MAX_INDEX_POINTER = 160; // 最大索引指针数量  index的宽度 
    localparam MAX_INDICES = 320; //最大indice数量         indices的宽度 4bit一个数据，一共80个数据
    localparam MAX_DATA_WIDTH = 640;
    localparam MAX_DATA_COUNT = 35;
    // --- 内部信号定义 ---

    // **优化**: 中间归约流水线寄存器 (stages 0 to DEPTH-1)
    // 声明宽度仍为 VEX_WIDTH，依赖综合器优化未使用的上位比特。
    // 如果 DEPTH=0 (LANES=1)，这将是一个空数组 [0:-1]，是合法的。
    logic [VEX_WIDTH-1:0] accum_reg [0:DEPTH-1];

    // **优化**: 最终累加结果寄存器，宽度为 DATA_WIDTH
    logic [DATA_WIDTH-1:0] final_accum_value_reg;

    //SPMM 完成标志
    logic spmm_finish;

    //暂存稀疏矩阵数据
    logic [1119:0] csr_data_reg;
    logic spmm_valid; //如果当前选到的位置有效
    logic [7:0] spmm_data_ptr = '0;
    logic [7:0] spmm_data_num;//稀疏矩阵中所有还没有处理的元素数量
    logic [127:0] spmm_row_data = '0;  //fixme 初始化为1？一个数据8bit 一行最多16个 128bit
    logic [15:0] spmm_row_index = '0; // 用于存储当前行的索引
    logic spmm_addr_ready = 0; // 地址准备好
    logic [4:0] spmm_load_count = '0;         // 用於計數加載的元素數量
    logic [4:0] spmm_index_count_r = '0;      // 時序註冊：已處理索引位置
    logic [4:0] spmm_row_data_num = '0; //本次处理的稀疏矩阵对应行上的元素数量

    logic [DATA_WIDTH-1:0] tmp_reg [0:LANES-1]; // 用于存储最终结果 lane个tep_reg
    logic [4:0] spmm_compute_indice_ptr = '0;
    logic spmm_compute_done_r = '0;
    logic [7:0] spmm_compute_indice_base = '0; // 用于存储 SPMM 计算的基地址
    logic spmm_compute_done_r_r = 1'b0;
    logic [15:0] spmm_total_index_buf [0:15]; // 用于存储16行的index数据
    logic [4:0] spmm_row_data_buf [0:15]; // 用于存储16行的data数量
    logic [3:0] row_stationary_reg [0:ROW_STATIONARY_NUM-1]; // 用于标识这4个常用行分别是dense matrix的哪几行，后面compute指令取数据需要这个

    logic row_index_ready;
    
    
    // --- Lane 信号定义 ---
    wire [DATA_WIDTH-1:0] pe_out [0:LANES-1];
    logic [DATA_WIDTH-1:0] pe_b_data [0:LANES-1];

    logic [LANES-1:0] spmm_add_done;

    // --- Lane 实例化 (使用 generate block) ---
    genvar i;
    generate
        for (i = 0; i < LANES; i = i + 1) begin : lane_gen_0
            lane #( .DATA_WIDTH(DATA_WIDTH) )
            lane_inst (
                .out   (pe_out[i]),
                .a     (vs2_data[i]), // 修改：使用数组索引，解决 ELAB-400
                .b     (pe_b_data[i]),//  csr data  pe_b_data是输入一行数据的四份 一个数组 有四个数
                .op    (op),
                .spmm_add_done_o  (spmm_add_done[i]),
                .vsew  (vsew)
            );
        end
    endgenerate

    // --- 输入数据激活逻辑 ---
    logic [DATA_WIDTH-1:0] vs1_data [0:LANES-1]; // 修改：改为数组类型
    logic [DATA_WIDTH-1:0] vs2_data [0:LANES-1]; // 修改：改为数组类型
    logic [DATA_WIDTH-1:0] csr_data [0:LANES-1]; // 修改：改为数组类型 

    // 改三个参数的位宽
    logic [MAX_INDEX_POINTER-1:0] spmm_index = '0; // 用于 SPMM 加载的索引数组
    logic [639:0] spmm_data = '0; // 用于 SPMM 数据加载的数组  改成80个数据的宽度 80*8 = 640
    logic [MAX_INDICES-1:0] spmm_indices = '0; // 用于 SPMM 加载的计数 
    logic [7:0] store_data_count;

    logic buf_load_en_r;
    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            buf_load_en_r <= '0;
        end else begin
            buf_load_en_r <= buf_load_en;
        end
    end
    
    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            csr_data_reg <= '0;
            store_data_count <= 0;
        end else begin
            if(buf_load_en_r && store_data_count < MAX_DATA_COUNT) begin
                csr_data_reg[(store_data_count)*32 +: 32] <= csr_data_i; //存储数据到稀疏矩阵寄存器
                store_data_count <= store_data_count + 1; //计数器加1
            end else if(store_data_count == MAX_DATA_COUNT) begin
                store_data_count <= 0; //计数器归零，准备下一次存储
            end
        end
    end

    always_comb begin // 将输入进来的csr格式数据分组存储备用
        if(~rstn) begin
            spmm_data = '0; // 初始化数据数组
            spmm_indices = '0; // 初始化计数数组
            spmm_index = '0; // 初始化索引数组
        end else if(op == PE_SPMM_CAL_INDEX && csr_load && buf_data_ready) begin
            spmm_index = csr_data_reg[135:0]; // 提取csr格式数据中的index信息 实际是17个索引有效 但为了方便把额外的存在了一个内存当中
            spmm_data = csr_data_reg[799:160]; // 提取csr格式数据中的data信息
            spmm_indices = csr_data_reg[1119:800]; // 提取csr格式数据中的indices信息
        end else begin
            spmm_index = spmm_index;
            spmm_data = spmm_data;
            spmm_indices = spmm_indices;    
        end
    end

//  不用改  主要看vs2_data  作为行数据（dense）
//  vs2_data是32bit的进，在lane当中在分开乘 所以不用改
    always_comb begin
        if (~rstn) begin
            for (int j = 0; j < LANES; j++) begin
                vs1_data[j] = '0;
                vs2_data[j] = '0;
            end
        end 
        else begin
            if (vrf_load) begin
                for (int j = 0; j < LANES; j++) begin
                    vs1_data[j] = vs1_data_i[(j*DATA_WIDTH)+:(DATA_WIDTH)]; // 修改：拆分向量为数组  vs1_data拆成4份然后给lane进行计算 每份32bit  放在lane当中是分成4分8bit来进行计算
                    vs2_data[j] = vs2_data_i[(j*DATA_WIDTH)+:(DATA_WIDTH)]; // 修改：拆分向量为数组
                end
            end else if (csr_load) begin
                for (int j = 0; j < LANES; j++) begin
                    vs2_data[j] = vs2_data_i[(j*DATA_WIDTH)+:(DATA_WIDTH)]; // 修改：拆分向量为数组
                    //对于csr数据的分配写在了后面，需要单独对每一行拆开来看
                end
            end else begin
                for (int j = 0; j < LANES; j++) begin
                    vs1_data[j] = '0;
                    vs2_data[j] = '0;
                end
            end
        end
    end



//index逻辑的修改 原先一个4bit 现在一个8bit  偏移量改成8bit  从index低位开始的  要保证新的csr和原来的csr的顺序一样
// fixme 这个spmm_load_count可能有问题 因为对于index来说 一直是非零

    logic [4:0] load_matrix_num = 0;
    logic load_done = 0;

    // 第一循環：組合邏輯計算總計數
    always_comb begin : Count_Index_Total
        if (op == PE_SPMM_CAL_INDEX && csr_load && (load_matrix_num == 5'b10000) && !buf_data_ready) begin//当剩余数据为0时代表这是一次新的spmm计算，此时重新对数据进行分析
            spmm_load_count = 1;
            buf_load_en = 1;//从buffer里面读出稀疏矩阵数据，同时需要通知dma从外部存储开始取下一段数据
        end else if (op == PE_SPMM_CAL_INDEX && (load_matrix_num == 5'b10000) && buf_data_ready)begin//剩余数据大于0，证明这还是一次旧的spmm操作，不需要重新计数
            if(buf_data_ready) begin
                for (int j = 1; (j*8) < MAX_INDEX_POINTER; j++) begin//从1开始是因为spmm_index[0]一定为0，但是这是有效的数据
                    if (spmm_index[j*8 +: 8] != 0) begin
                        spmm_load_count++;//得到本次csr数据中index的有效数量
                    end else begin
                        spmm_load_count = spmm_load_count;  
                    end
                end
            end
            buf_load_en = 0;
        end else if (op == PE_SPMM_CAL_INDEX && load_matrix_num && buf_data_ready)begin//剩余数据大于0，证明这还是一次旧的spmm操作，不需要重新计数
            buf_load_en = 0;
            spmm_load_count = spmm_load_count;
        end else begin
            buf_load_en = buf_load_en;
        end
    end
    

/*
    状态机的功能：有三个状态，IDLE、SEARCH和STORE
    在SEARCH阶段对一行的sparse data进行处理，得到这一行的index和data_num
    在STORE阶段将这一行的两个数据存进对应的buffer当中
    在重复16次之后，回到IDLE等待下一次cal_index指令
*/
    // 三段式状态机：IDLE -> SEARCH -> STORE
    // 三段式状态机：IDLE -> SEARCH -> STORE
    typedef enum logic [2:0] {IDLE, SEARCH, STORE, CAL_STATIONARY} state_t;
    state_t state, next_state;

    // 状态机相关寄存器
    logic [3:0] row_cnt; // 计数已处理的行数（最多16行）
    logic [4:0] cur_data_num; // 当前行的data数量
    // 状态转移
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= IDLE;
            row_cnt <= 0;
            spmm_index_count_r <= 0;
            // 可根据需要复位其它相关信号
        end else begin
            state <= next_state;
            if (state == IDLE && next_state == SEARCH) begin
                row_cnt <= 0;
                spmm_index_count_r <= 0;
            end else if ((state == STORE && next_state == SEARCH)) begin
                row_cnt <= row_cnt + 1;
                spmm_index_count_r <= spmm_index_count_r + 1;
            end
        end
    end

    always_comb begin
        if(state == SEARCH) begin
            cur_data_num      = spmm_index[(spmm_index_count_r+1)*8 +: 8] - spmm_index[spmm_index_count_r*8 +: 8];
            spmm_row_data_num = spmm_index[(spmm_index_count_r+1)*8 +: 8] - spmm_index[spmm_index_count_r*8 +: 8];
        end else if(next_state == CAL_STATIONARY) begin
            spmm_row_data_num = 0;
        end else begin
            cur_data_num      = cur_data_num;
            spmm_row_data_num = spmm_row_data_num;
        end
    end

    // 状态转移逻辑
    always_comb begin
        case (state)
            IDLE: begin
                if (op == PE_SPMM_CAL_INDEX && !cal_stationary_done && buf_data_ready) begin
                    next_state = SEARCH;
                end
                index_cal_done = 1'b0;
            end
            SEARCH: begin
                if (row_cnt < 16 && row_index_ready) begin
                    next_state = STORE;
                end else if (row_cnt == 16) begin
                    next_state = CAL_STATIONARY;
                end
                index_cal_done = 1'b0;
            end
            STORE: begin
                if (row_cnt < 15) begin
                    next_state = SEARCH;
                end else begin
                    next_state = CAL_STATIONARY;
                    index_cal_done = 1'b1; // 计算完成信号在最后一个STORE阶段结束时拉高
                end
            end
            CAL_STATIONARY: begin
                if(cal_stationary_done) begin
                    next_state = IDLE;
                end else begin
                    next_state = CAL_STATIONARY;
                end
            end
            default: begin
                next_state = IDLE;
                index_cal_done = 1'b0;
            end
        endcase
    end

    // STORE阶段：将每行的index和data_num存入buffer
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (int i = 0; i < 16; i++) begin
                spmm_total_index_buf[i] <= '0;
                spmm_row_data_buf[i] <= '0;
            end
        end else if (state == STORE) begin
            spmm_total_index_buf[row_cnt] <= spmm_row_index;
            spmm_row_data_buf[row_cnt] <= cur_data_num;
        end
    end

    //对spmm_compute_done打一拍
    always_ff @(posedge clk or negedge rstn) begin
        if(rstn == 1'b0) begin
            spmm_compute_done_r_r <= '0;
        end else begin
            spmm_compute_done_r_r <= spmm_compute_done;
        end
    end


    //计算当前要计算的spmm的元素位置
    //spmm_row_index的更新似乎没问题 indices的数据大小在0-15 
    //将spmm_data和spmm_indices转换为适合计算的格式spmm_row_data和spmm_row_index
    //spmm_row_data是128bit，16个元素，一个元素8bit,把该行的数据按照位置存起来
    //spmm_row_index是16bit，位图形式，对应稠密矩阵的一行
    // 原 always_comb 逻辑转换为时序逻辑
    // 新 always_ff 块，处理原 always_comb 逻辑并添加清零
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            spmm_data_ptr <= '0;
            spmm_addr_ready <= 1'b0; // 假设复位时清零
        end else begin
            // 默认保持当前值
            spmm_data_ptr <= spmm_data_ptr;

            // 重置逻辑
            if (!load_matrix_num && op == PE_SPMM_CAL_INDEX) begin
                spmm_data_ptr <= '0;
            end

            // SEARCH 状态逻辑
            if (state == SEARCH) begin
                spmm_addr_ready <= 1'b1;
                if (spmm_row_data_num != '0  && row_index_ready == 0) begin
                    spmm_data_ptr <= spmm_row_data_num + spmm_data_ptr;
                    // SEARCH 赋值完成后清零 spmm_row_data
                end else begin
                    spmm_data_ptr <= spmm_data_ptr;
                end
            end else begin
                spmm_addr_ready <= 1'b0;
            end
        end
    end

    // 原 always_ff 块，保持不变
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            spmm_row_index <= '0;
            row_index_ready <= 1'b0;
            //spmm_row_data <= '0;
        end else if (state == STORE) begin
            spmm_row_index <= '0; // 存完一行后清零
            row_index_ready <= 1'b0;
            //spmm_row_data <= '0;
        end else if (state == SEARCH) begin
            // 正常赋值逻辑
            if (spmm_row_data_num != '0 && row_index_ready == 0) begin
                for (int j = 0; j < 16; j++) begin
                    if (j < spmm_row_data_num) begin
                        spmm_row_index[spmm_indices[(spmm_data_ptr + j) * 4 +: 4]] <= 1'b1;
                        //spmm_row_data [spmm_indices[(spmm_data_ptr + j) * 4 +: 4] * DATA_WIDTH +: DATA_WIDTH] <= spmm_data[(spmm_data_ptr + j) * DATA_WIDTH +: DATA_WIDTH];
                    end else begin
                        //spmm_row_data <= spmm_row_data;
                        spmm_row_index = spmm_row_index;
                    end
                end
                row_index_ready <= 1'b1;
                // SEARCH 赋值完成后清零 spmm_row_index
            end else if(spmm_row_data_num == '0) begin
                row_index_ready <= 1'b1;
            end
        end
    end
    logic [4:0] row_counts [16];            // 每行的非零元素计数
    logic [3:0] sorted_rows [16];           // 按非零元素数量排序的行索引
    logic [4:0] sorted_counts [16];         // 对应排序后的计数
    logic [3:0] top_rows [4];        // 最多非零元素的四行索引
    logic [4:0] top_counts [4];  
    // 统计每行的 1 数量
    always_comb begin
        if(state == CAL_STATIONARY) begin
            for (int i = 0; i < 16; i++) begin
                row_counts[i] = 0;
                for (int j = 0; j < 16; j++) begin
                    row_counts[i] += spmm_total_index_buf[j][i]; // 累加每行的 1
                end
                sorted_rows[i] = i; // 初始化行索引
                sorted_counts[i] = row_counts[i];
            end

            // 简单冒泡排序，找出非零元素最多的四行
            for (int i = 0; i < 15; i++) begin
                for (int j = 0; j < 15 - i; j++) begin
                    if (sorted_counts[j] < sorted_counts[j+1] || 
                        (sorted_counts[j] == sorted_counts[j+1] && sorted_rows[j] > sorted_rows[j+1])) begin
                        // 交换计数
                        logic [4:0] temp_count;
                        logic [3:0] temp_row;
                        temp_count = sorted_counts[j];
                        sorted_counts[j] = sorted_counts[j+1];
                        sorted_counts[j+1] = temp_count;
                        // 交换行索引
                        temp_row = sorted_rows[j];
                        sorted_rows[j] = sorted_rows[j+1];
                        sorted_rows[j+1] = temp_row;
                    end
                end
            end

            // 输出前四行
            for (int i = 0; i < ROW_STATIONARY_NUM; i++) begin
                top_rows[i] = sorted_rows[i];//没有按照序号进行排序，而是按照重复使用程度排序，需要重排
                top_counts[i] = sorted_counts[i];
            end
        end
    end

    //对top_rows进行重排序，然后发送给vid
    always_comb begin
        automatic int j = 0;
        if(cal_stationary_done) begin
            for(int i = 0; i < 16; i++) begin
                if(row_index_dense[i] == 1'b1) begin
                    sorted_top_rows[j] = i;
                    j = j + 1;
                end
            end
        end
    end


    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            row_index_dense <= '0;
        end else begin
            if(state == CAL_STATIONARY) begin
                for(int j = 0; j < ROW_STATIONARY_NUM; j++) begin
                    row_index_dense[top_rows[j]] <= 1'b1;  // 标记为常用行
                end
                cal_stationary_done <= 1'b1;
            end else if(state == IDLE && op == PE_SPMM_CAL_INDEX) begin
                row_index_dense <= '0;
                cal_stationary_done <= 1'b0;
            end else begin
                row_index_dense <= row_index_dense;
                cal_stationary_done <= 1'b0;
            end
        end
    end

    logic spmm_addr_ready_r;
    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            spmm_addr_ready_r <= '0;
        end else begin
            spmm_addr_ready_r <= spmm_addr_ready;
        end
    end


    //对稀疏矩阵进行计数，一共16行，16行全部load完重置进入下一个矩阵
    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            load_matrix_num <= 5'b10000;
            load_done <= 1'b0; 
        end  else begin
            if(load_matrix_num == '0 && op == PE_SPMM_CAL_INDEX) begin
                load_done <= 1'b1;
            end else if(load_matrix_num == 0 && op != PE_SPMM_CAL_INDEX)begin
                load_matrix_num <= 5'b10000;  //16个
                load_done <= 1'b0;
            end else if(spmm_addr_ready && !spmm_addr_ready_r) begin
                load_matrix_num <= load_matrix_num - 1;
            end else begin
                load_matrix_num <= load_matrix_num;
                load_done <= 1'b0; 
            end
        end
    end

    assign addr_ready = spmm_addr_ready; // 输出地址准备好信号


    //数据给到lane当中还是要一个lane给32bit（4个数） 在lane里面在拆开算
    //把上面得到的spmm_row_data给到csr_data（一行的数据）
    always_comb begin //分配好spmm计算要用的稀疏矩阵操作数
        if (~rstn) begin
            for (int j = 0; j < LANES; j++) begin
                csr_data[j] = '0;
            end
        end 
        else begin
            if (csr_load) begin //在spmm计算指令的时候全程保持csr_load为高，前面设置了条件所以在计算指令不会触发其余load部分
                for (int j = 0; j < LANES; j++) begin
                    csr_data[j] = spmm_row_data[(j*DATA_WIDTH)+:(DATA_WIDTH)]; // 修改：拆分向量为数组
                end
            end 
        end
    end

    //Load指令逻辑 此时应该取出存在total_index_buf中的一行index输出与index，需要一个计数器来控制这一次要输出第几行
    logic [4:0] load_index_count = '0;
    logic load_row_index_r;
    logic [15:0] row_index_r;

    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            load_row_index_r <= 1'b0;
        end else begin
            load_row_index_r <= load_row_index_i;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin : load_index_counter
        if(~rstn) begin
            load_index_count <= '0;
        end else begin
            if(load_index_count == 16 && op == PE_SPMM_COMPUTE && !load_row_index_i) begin
                load_index_count <= '0;
            end else if(op == PE_SPMM_LOAD_DENSE && load_row_index_i && !load_row_index_r) begin//取上升沿防止多次触发计数
                load_index_count <= load_index_count + 1;
            end else begin
                load_index_count <= load_index_count;
            end
        end
    end
//下面有修改有新增
    always_comb begin : load_row_index_logic

        if(op == PE_SPMM_LOAD_DENSE && load_row_index_i && !load_row_index_r) begin
            compute_row_data_num = '0;
        end else if(op == PE_SPMM_LOAD_DENSE && load_row_index_r && !index_ready) begin
            row_index_r = spmm_total_index_buf[load_index_count - 1];
            for(int i = 0; i < 16; i++) begin
                if(spmm_total_index_buf[load_index_count - 1][i] == 1'b1) begin
                    compute_row_data_num = compute_row_data_num + 1;
                end else begin
                    compute_row_data_num = compute_row_data_num;
                end
            end
                index_ready = 1'b1;
        end else if(op != PE_SPMM_LOAD_DENSE) begin
            row_index_r = '0;
            compute_row_data_num = compute_row_data_num;
            index_ready = 1'b0;
        end else begin
            row_index_r = row_index_r;
            index_ready = index_ready;
            compute_row_data_num = compute_row_data_num;
        end
    end

    logic [15:0] row_extra_index;
    logic [15:0] row_stationary_index;

    always_comb begin : Index_Comparator
        row_extra_index = ~row_index_dense & row_index_r;//得到不包含常用行的index
        row_stationary_index = row_index_dense & row_index_r;//得到这一行Index用到了哪几个常用行
    end

    logic [4:0] extra_load_num_r = 0;
    always_comb begin
        if (spmm_compute_done) begin
            extra_load_num_r = '0;
        end else 
        if (index_ready == 1'b1) begin
            for(int i = 0; i < 16; i++) begin
                extra_load_num_r += row_extra_index[i];
            end
        end else begin
                extra_load_num_r = extra_load_num_r;
        end
    end

    //给extra一个数组，用来标识vrf中不固定的内存位置存放的是哪几行
    always_comb begin
        automatic int j = 0;
        if(cal_stationary_done) begin
            for(int i = 0; i < 8; i++) begin
                extra_rows_id[i] = '0;
            end
        end else if(index_ready) begin
            for(int i = 0; i < 16; i++) begin
                if(row_extra_index[i] == 1'b1) begin
                    extra_rows_id[j] = i;
                    j = j + 1;
                end
            end
        end
    end


    always_comb begin
        automatic int j = 0;
        if(cal_stationary_done) begin
            for(int i = 0; i < 8; i++) begin
                compute_rows_id[i] = '0;
            end
        end else if(index_ready) begin
            for(int i = 0; i < 16; i++) begin
                if(row_index_r[i] == 1'b1) begin
                    compute_rows_id[j] = i;
                    j = j + 1;
                end
            end
        end
    end
    
    assign extra_load_num_o = extra_load_num_r;
    assign row_index = row_index_r; // 输出当前行索引


    // --- 完成信号逻辑 ---
    // (代码同前，保持不变)
     always_comb begin
        comp_done = spmm_compute_done | spmm_add_done;
    end

// --- B 操作数选择逻辑 ---
//每次vs_data2分四块进入lane，是一行。所以对于pe_b_data每次进入的数据是一样的
    always_comb begin
        case (operand_select)
            PE_OPERAND_VS1: begin
                for (int j = 0; j < LANES; j++) begin
                    pe_b_data[j] = vs1_data[j];
                end
            end
            PE_OPERAND_CSR:begin
                if(spmm_compute_indice_ptr < compute_row_data_num && vrf_load) begin
                    for (int j = 0; j < LANES; j++) begin
                        pe_b_data[j] =spmm_data[(spmm_compute_indice_base + spmm_compute_indice_ptr) * DATA_WIDTH +: DATA_WIDTH];
                        //根据indice对应取出本次计算需要用到的稀疏矩阵元素
                        //csr_data是有16个元素的 一行的csr数据 这里[]是选择了csr_data里非零元素然后把这个数据广播到所有的lane当中
                    end
                end else begin
                    for (int j = 0; j < LANES; j++) begin
                        pe_b_data[j] ='0;
                    end
                end
            end 
            default: begin
                for (int j = 0; j < LANES; j++) begin
                    pe_b_data[j] = '0;
                end
            end
        endcase
    end


    //For spmm compute

    logic [4:0] compute_matrix_num;

    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            for(int j = 0; j < LANES; j++) begin
                tmp_reg[j] <= '0;//用于存储输出行每个位置元素的值，经过累加得出最终结果
            end
            spmm_compute_indice_ptr <= '0;//偏移地址
            spmm_compute_done_r <= '0;
            spmm_compute_indice_base <= '0;//基地址，基地址和偏移地址在上面的pe_b_data赋值的位置共同作用
        end else if(compute_matrix_num == '0 && op == PE_SPMM_COMPUTE) begin
            spmm_compute_indice_base <= '0;
            spmm_compute_indice_ptr <= '0;
        end else if(op == PE_SPMM_LOAD_DENSE) begin
            spmm_compute_done_r <= 1'b0;
        end
        else if(vex_en && op == PE_SPMM_COMPUTE) begin
            if(compute_row_data_num == '0) begin
                spmm_compute_done_r <= 1'b1;
            end else 
            if(  0 < spmm_compute_indice_ptr <= compute_row_data_num) begin
                for(int j = 0; j < LANES; j++) begin
                    tmp_reg[j] <= pe_out[j] + tmp_reg[j];//tmp_reg值的累加
                end
                if(spmm_compute_indice_ptr < compute_row_data_num && vrf_load) begin
                    spmm_compute_indice_ptr <=  spmm_compute_indice_ptr + 1;
                    spmm_compute_done_r <= spmm_compute_done_r;
                end else 
                if(spmm_compute_indice_ptr == compute_row_data_num) begin
                    spmm_compute_indice_base <= spmm_compute_indice_base + compute_row_data_num; // 更新基地址
                    spmm_compute_done_r <= 1'b1;//计算完成
                    spmm_compute_indice_ptr <= '0;
                end else begin
                    spmm_compute_done_r <= 1'b0;
                end
            end else begin
                spmm_compute_indice_ptr <= '0;
                spmm_compute_done_r <= 1'b0;
            end
        end else begin
            for(int j = 0; j < LANES; j++) begin
                tmp_reg[j] <= '0;
            end
            spmm_compute_indice_ptr <= '0;
            spmm_compute_done_r <= '0;
        end
    end

    //for spmm add  todo
    //也用spmm_add_done_r和spmm_add_done的逻辑去写 todo
    //目标是计算完后，spmm_add_done拉高一周期，然后给vid，拉高write_en，写入vrf当中。

    //compute计数器，用于计数稀疏矩阵还剩几行没有计算
    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            compute_matrix_num <= '0;
        end else if(!compute_matrix_num && op == PE_SPMM_COMPUTE) begin
            compute_matrix_num <= 5'b10000;
        end else if(spmm_compute_done && !spmm_compute_done_r_r)begin
            compute_matrix_num <= compute_matrix_num - 1;
        end else begin
            compute_matrix_num <= compute_matrix_num;
        end
    end

    assign spmm_compute_done = spmm_compute_done_r; // 输出 SPMM 计算完成信号

    // --- 暂停信号定义 (保持不变) ---
    `define HOLD_VLSU_BIT   3
    `define HOLD_VEX_BIT    2
    `define HOLD_VID_BIT    1
    `define HOLD_PC_BIT     0
    `define HOLD_ENABLE     1'b1
    `define HOLD_DISABLE    1'b0

    // -- 时序逻辑部分：控制流水线和累加 --
    always_ff @(posedge clk or negedge rstn) begin
        if (~rstn) begin
            // 复位中间流水线寄存器
            if (DEPTH > 0) begin // 只有存在中间寄存器时才复位
                for (int i = 0; i < DEPTH; i++) begin // 注意循环边界到 DEPTH-1
                    accum_reg[i] <= '0;
                end
            end
            // **优化**: 复位最终累加器
            final_accum_value_reg <= '0;

            hold_req_o <= 4'b0000;
        end
        else if (vex_en) begin
            if(op == PE_SPMM_LOAD_DENSE) begin
                hold_req_o <= 4'b0000; // 先默认不暂停，下面再设置
                if(spmm_load_done == 1'b1) begin
                    hold_req_o[`HOLD_PC_BIT]  <= `HOLD_DISABLE;
                    hold_req_o[`HOLD_VID_BIT] <= `HOLD_DISABLE;
                    hold_req_o[`HOLD_VEX_BIT] <= `HOLD_ENABLE;
                    hold_req_o[`HOLD_VLSU_BIT]<= `HOLD_DISABLE;
                end else begin
                    hold_req_o[`HOLD_PC_BIT]  <= `HOLD_ENABLE;
                    hold_req_o[`HOLD_VID_BIT] <= `HOLD_DISABLE;
                    hold_req_o[`HOLD_VEX_BIT] <= `HOLD_ENABLE;
                    hold_req_o[`HOLD_VLSU_BIT]<= `HOLD_DISABLE;
                    final_accum_value_reg <= '0;
                end
            end
            else if(op == PE_SPMM_COMPUTE) begin
                hold_req_o <= 4'b0000; // 先默认不暂停，下面再设置
                if(spmm_compute_done == 1'b1) begin  //hold_req_out = 0100
                    hold_req_o[`HOLD_PC_BIT]  <= `HOLD_DISABLE;
                    hold_req_o[`HOLD_VID_BIT] <= `HOLD_DISABLE;
                    hold_req_o[`HOLD_VEX_BIT] <= `HOLD_ENABLE;
                    hold_req_o[`HOLD_VLSU_BIT]<= `HOLD_DISABLE;
                end else begin                        //hold_req_out = 0111
                    hold_req_o[`HOLD_PC_BIT]  <= `HOLD_ENABLE;  //改成DISABLE 不暂停pc 继续往下读 相加指令
                    hold_req_o[`HOLD_VID_BIT] <= `HOLD_ENABLE;
                    hold_req_o[`HOLD_VEX_BIT] <= `HOLD_ENABLE;
                    hold_req_o[`HOLD_VLSU_BIT]<= `HOLD_DISABLE;
                    final_accum_value_reg <= '0;//自己定义一个新的，不用旧的了
                end
            end
            else begin // 其他或无效操作
                hold_req_o <= 4'b0000;
                // **优化**: 复位最终累加器状态
                final_accum_value_reg <= '0;
                // 复位中间流水线寄存器
                if (DEPTH > 0) begin
                    for (int i = 0; i < DEPTH; i++) begin
                        accum_reg[i] <= '0;
                    end
                end
            end
        end // end else if (vex_en)
        else begin // 模块未使能
            hold_req_o <= 4'b0000;
             // **优化**: 复位最终累加器状态
            final_accum_value_reg <= '0;
            // 复位中间流水线寄存器
            if (DEPTH > 0) begin
                 for (int i = 0; i < DEPTH; i++) begin
                     accum_reg[i] <= '0;
                 end
            end
        end // end else (模块未使能)
    end // end always_ff

    // --- 输出选择逻辑 ---、
    always_comb begin
        case (op)
            PE_SPMM_COMPUTE:begin
                //注意，这里需要根据具体是第几位的数据来决定输出的时候放在输出数据的哪个位置 todo
                if (spmm_compute_done) begin
                    arith_output = {tmp_reg[15], tmp_reg[14], tmp_reg[13], tmp_reg[12],tmp_reg[11], tmp_reg[10], tmp_reg[9], tmp_reg[8],tmp_reg[7], tmp_reg[6], tmp_reg[5], tmp_reg[4],tmp_reg[3], tmp_reg[2], tmp_reg[1], tmp_reg[0]}; 
                    // 输出结果,16个tmp_reg的结果对应一行中的16个元素，拼接输出128bit
                end else begin
                    arith_output = '0;
                end
            end
            PE_ARITH_ADD:begin
            if(spmm_add_done) begin  //spmm_add_done todo 由于数据一进来(vs1,vs2)，计算pe_out计算好，所以这个spmm_add_done应该在进来或者算好拉高 作为vex的输出信号
                arith_output = {pe_out[15], pe_out[14], pe_out[13], pe_out[12],pe_out[11], pe_out[10], pe_out[9], pe_out[8],pe_out[7], pe_out[6], pe_out[5], pe_out[4],pe_out[3], pe_out[2], pe_out[1], pe_out[0]};
            end else begin
                arith_output = '0;
            end
            end
            default: begin
                arith_output = '0;
            end
        endcase
    end

endmodule



// --- lane 子模块 ---
// 功能：单个处理单元，支持加法和乘法运算，根据 vsew 处理 int8/int16/int32
// 注意：内部仍按 32 位处理，DATA_WIDTH 参数仅用于接口匹配
// spmm没有用到lane中的加法功能，因此先注释掉，后面如果需要去掉注释就可以直接使用

// 现在改成8位处理

module lane #(
    parameter DATA_WIDTH = 8
) (
    output logic [DATA_WIDTH-1:0] out,   // 输出：运算结果 (8 位)
    output logic spmm_add_done_o,        // 输出：加法完成标志
    input wire [DATA_WIDTH-1:0] a,       // 输入：A 操作数 (VS2，8 位向量数据)
    input wire [DATA_WIDTH-1:0] b,       // 输入：B 操作数 (VS1/CSR，8 位数据)
    input wire [3:0] op,                 // 输入：运算类型（加、乘）
    input wire [1:0] vsew                // 输入：元素宽度（仅支持 00: 8 位）
);
    // 内部信号
    logic [15:0] mult_int8;  // 8 位乘法结果（16 位宽）
    logic [8:0] add_int8;    // 8 位加法结果（9 位宽）

    // 运算逻辑：仅支持 8 位运算 (vsew=2'b00)
    always_comb begin
        if (vsew == 2'b00) begin // int8: 单个 8 位元素
            mult_int8 = a * b;   // 8 位乘法
            add_int8 = a + b;    // 8 位加法
            case (op)
                PE_ARITH_ADD: begin
                    out = add_int8[7:0];
                    spmm_add_done_o = 1'b1;
                end
                PE_SPMM_COMPUTE: begin
                    out = mult_int8[7:0];
                    spmm_add_done_o = 1'b0;
                end
                default: begin
                    out = '0;
                    spmm_add_done_o = 1'b0;
                end
            endcase
        end else begin // 非 8 位情况
            out = '0;
            spmm_add_done_o = 1'b0;
        end
    end
endmodule