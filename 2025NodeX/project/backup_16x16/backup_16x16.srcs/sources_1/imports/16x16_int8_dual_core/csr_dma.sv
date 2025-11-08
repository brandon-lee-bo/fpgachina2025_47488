//挂载在axi总线上，在外部存储和csr buffer之间传递稀疏矩阵数据，本身不负责存储
//csr buffer内部存储空间大小刚好是稀疏矩阵数据的大小，因此没有必要额外配置地址信息
//读取数据的初始地址由scalar_operand决定，数据长度保持不变，因此没有设定描述符
//sparse buffer把数据输出给vex的同时，向dma发送使能信号，dma开始读取下一个稀疏矩阵的数据
//目前的设计是最一开始给一个让dma从外部读取数据的指令，后面就让dma在load指令和store指令期间去外部取数据

//vrf和sparse_buf需要得到的数据位宽大小是不同的，sparse buf需要32位但vrf需要128位



module dma (
    input clk,
    input rstn,
    input nib_hold_req_i,

    input [31:0] addr_data_i, //外部存储地址输入
    input [7:0] max_data_count,//类似于vlsu的load_cnt和write_cnt，这里感觉可以简化成一个，没有同时读写的需求
    input dma_mode_i, //0表示sparse_buffer,1表示vrf,区别在于需要的输出数据位宽不同

    //读部分
    input instr_valid_i, //指令有效信号,来自vid的输入
    input store_mem_en, //从外部存储数据到dma，来自vex
    input [31:0] store_data, //来自总线的数据，来自外部存储
    input buf_load_en, //从buffer load稀疏矩阵数据给vex，每个矩阵第一次load的时候会拉高这个信号一个周期
    output logic        data_req_o, //数据请求信号
    output logic        sparse_store_done,//本次稀疏矩阵的数据全部存储完成
    output logic        data_out_flag,//数据输出标志，表示当前有数据可以输出，通知buffer接受数据
    output logic [31:0] load_data_o, //输出稀疏矩阵数据
    output logic dma_done_o,//类似vlsu_done_o

    //写部分
    input write_en,
    input [31:0] write_data,//写数据
    output logic write_req_o,
    output logic [31:0] write_data_o,//往外部存储写入的数据

    output logic [31:0] external_addr //外部存储地址
);
    logic [7:0]   data_count; //数据计数器，用于记录已经从外部读取了多少个32位数据
    
    //一共608位，其中32位index数据,64位indices数据，512位data数据,根据32位的数据总线宽度，一共需要19个周期读取全部数据
    //加上往sparse_buf存储完全部数据，大约需要22个周期，4个compute指令的时间足够完成这些内容
    //安排在compute指令期间防止与vlsu产生总线竞争

    //localparam MAX_DATA_COUNT = 101; //最大数据计数值
    localparam DATA_WIDTH = 32; //每次读取数据的宽度,数据总线位宽的大小

    //使用一个计数器来计数当前读取了多少位数据，等到读取完一整个稀疏矩阵的数据之后就应该停下等待使用,并发出一个完成的信号。
    //在compute指令dma可以全程向外部取数据，在load指令dma只会拉高一个周期，在exec状态会拉高

    logic dma_load_en;
    assign dma_load_en = instr_valid_i || store_mem_en; //dma使能信号

    logic hold_data = '0;

    logic dma_en_r;
    logic dma_en_r_r;
    always_ff @(posedge clk or negedge rstn) begin
        if(~rstn) begin
            dma_en_r <= 1'b0;
            dma_en_r_r <= 1'b0;
        end else begin
            dma_en_r <= dma_load_en;
            dma_en_r_r <= dma_en_r;
        end
    end


    //写逻辑，向外部写数据
 typedef enum logic [2:0] {
        IDLE,
        READ_START,
        READ_DATA,
        READ_DONE,
        WRITE_START,
        WRITE_DATA,
        WRITE_DONE
    } dma_state_e;

    dma_state_e state, next_state;

    logic [31:0] addr_reg;

    // 状态转移
    always_ff @(posedge clk or negedge rstn) begin
        if (~rstn) begin
            state <= IDLE;
            data_count <= 0;
            addr_reg <= 32'h0;
            external_addr <= 32'h0;
        end else begin
            state <= next_state;
            // 读相关
            if (state == READ_START) begin
                addr_reg <= addr_data_i;
                external_addr <= addr_data_i;
                data_count <= 1;
            end else if (state == READ_DATA && dma_load_en) begin
                addr_reg <= addr_reg + 32'h4;
                external_addr <= addr_reg + 32'h4;
                data_count <= data_count + 1;
            end else if (state == READ_DONE) begin
                data_count <= 0;
                addr_reg <= addr_reg + 32'h4;
                external_addr <= addr_reg + 32'h4;
            end
            // 写相关
            if (state == WRITE_START) begin
                addr_reg <= addr_data_i;
                external_addr <= addr_data_i;
            end else if (state == WRITE_DATA) begin
                external_addr <= addr_data_i;
            end else if(state == WRITE_DONE) begin
                data_count <= 0;
                addr_reg <= addr_reg + 32'h4;
                external_addr <= addr_data_i;
        end
    end
    end

    // 状态机
    always_comb begin
        next_state = state;
        data_req_o = 0;
        data_out_flag = 0;
        hold_data = 0;
        write_req_o = 0;

        case (state)
            IDLE: begin
                if (!nib_hold_req_i && store_mem_en) begin
                    next_state = READ_START;
                end else if(!nib_hold_req_i && instr_valid_i) begin
                    next_state = READ_START;
                end else if (!nib_hold_req_i && write_en) begin
                    next_state = WRITE_START;
                end
                sparse_store_done = sparse_store_done;
            end
            READ_START: begin
                next_state = READ_DATA;
                data_req_o = 1;
                data_out_flag = 0;
                sparse_store_done = 0;
            end
            READ_DATA: begin
                if(dma_mode_i == 1'b0) begin
                    if (data_count < max_data_count - 1 && !nib_hold_req_i && dma_load_en) begin
                        next_state = READ_DATA;
                        data_req_o = 1;
                        data_out_flag = 1;
                        sparse_store_done = 0;
                    end else if (data_count == max_data_count - 1 && !nib_hold_req_i && dma_load_en) begin
                        next_state = READ_DONE;
                        data_req_o = 1;
                        data_out_flag = 1;
                        sparse_store_done = 0;
                    end else if (nib_hold_req_i) begin
                        hold_data = 1;
                        data_req_o = 0;
                        data_out_flag = 0;
                        sparse_store_done = 0;
                        next_state = READ_DATA;
                    end else begin
                        next_state = READ_DATA;
                        data_req_o = 0;
                        data_out_flag = 0;
                        sparse_store_done = 0;
                    end
                end else begin//给vrf的情况下，每次数据需要读取4份数据拼成一个128位的数据才能输出
                    if (data_count < 4 - 1 && !nib_hold_req_i) begin
                        next_state = READ_DATA;
                        data_req_o = 1;
                        data_out_flag = 0;
                        sparse_store_done = 0;
                    end else if (data_count == 4 - 1 && !nib_hold_req_i) begin
                        next_state = READ_DONE;
                        data_req_o = 1;
                        data_out_flag = 0;
                        sparse_store_done = 0;
                    end else if (nib_hold_req_i) begin
                        hold_data = 1;
                        data_req_o = 0;
                        data_out_flag = 0;
                        sparse_store_done = 0;
                        next_state = READ_DATA;
                    end else begin
                        next_state = READ_DATA;
                        data_req_o = 0;
                        data_out_flag = 0;
                        sparse_store_done = 0;
                    end
                end
            end
            READ_DONE: begin
                sparse_store_done = 1;
                dma_done_o = 1;
                data_req_o = 0;
                data_out_flag = 1;
                next_state = IDLE;
            end
            WRITE_START: begin
                write_req_o = 1;
                next_state = WRITE_DATA;
            end
            WRITE_DATA: begin
                write_req_o = 1;
                if (!nib_hold_req_i) begin
                    next_state = WRITE_DONE;
                end else if(!write_en)begin
                    next_state = WRITE_DONE;
                end else begin
                    next_state = WRITE_DATA;
                end
            end
            WRITE_DONE: begin
                write_req_o = 0;
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    always_comb begin : load_data_out
        if(hold_data) begin
            load_data_o = load_data_o;
        end else if(data_out_flag) begin
            load_data_o = store_data;
        end else begin
            load_data_o = 32'h0000_0000;
        end
    end

    always_comb begin : write_data_out
        if(hold_data) begin
            write_data_o = write_data_o;
        end else if(write_req_o) begin
            write_data_o = write_data;
        end else begin
            write_data_o = 32'h0000_0000;
        end
    end
endmodule