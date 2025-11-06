//接口与axi4协议不适配，为了方便选择自己写一个简单的总线结构

//支持多主多从，不同的主机从机进程可以并行执行，每个进程分配一个单独的id，防止干扰
//采用部分连接，特定的master只与特定的slave连接
//这个总线目前有6个master，分别给两个core的data、instr、scalar接口,3个slave，分别给存储数据的sdram和存储instr、scalar的nvm

//未解决问题：软件怎么分开给到两个core，两个core怎么从同一个sdram中取出需要的数据 todo

module nib(
    input clk,
    input rstn,

    input                   core_0_bus_spare,
    input                   core_1_bus_spare,
    input   wire            core_0_activate,
    input   wire            core_1_activate,
    //master0 分给core0的data接口，负责从外部存储读取数据，或将内部数据写入外部存储
    input   wire            m0_data_req_i,  //core0 data端口读请求
    input   wire    [31:0]  m0_addr_i,      //core0 data端口读/写请求地址
    output  logic   [31:0]  m0_rd_data_o,   //core0 data端口读数据
    input   wire            m0_wr_en_i,     //core0 data端口写使能
    input   wire    [31:0]  m0_wr_data_i,   //core0 data端口写数据
    output  logic           m0_hold_o,      //core0 暂停请求

    //master1 分给core0的instr接口，负责从外部存储读取指令，不需要向外部进行写入操作
    input   wire            m1_data_req_i,  //core0 instr端口读请求
    input   wire    [31:0]  m1_addr_i,      //core0 instr端口读/写请求地址
    output  logic   [31:0]  m1_rd_data_o,   //core0 instr端口读数据
    input   wire            m1_wr_en_i,     //core0 instr端口写使能
    input   wire    [31:0]  m1_wr_data_i,   //core0 instr端口写数据

    //master2 分给core0的scalar接口，负责从外部存储读取标量操作数，不需要向外部进行写入操作
    input   wire            m2_data_req_i,  //core0 scalar端口读请求
    input   wire    [31:0]  m2_addr_i,      //core0 scalar端口读/写请求地址
    output  logic   [31:0]  m2_rd_data_o,   //core0 scalar端口读数据
    input   wire            m2_wr_en_i,     //core0 scalar端口写使能
    input   wire    [31:0]  m2_wr_data_i,   //core0 scalar端口写数据

    //master3 分给core1的data接口，负责从外部存储读取数据，或将内部数据写入外部存储
    input   wire            m3_data_req_i,  //core1 data端口读请求
    input   wire    [31:0]  m3_addr_i,      //core1 data端口读/写请求地址
    output  logic   [31:0]  m3_rd_data_o,   //core1 data端口读数据
    input   wire            m3_wr_en_i,     //core1 data端口写使能
    input   wire    [31:0]  m3_wr_data_i,   //core1 data端口写数据
    output  logic           m3_hold_o,      //core1 暂停请求

    //master4 分给core1的instr接口，负责从外部存储读取指令，不需要向外部进行写入操作
    input   wire            m4_data_req_i,  //core1 instr端口读请求
    input   wire    [31:0]  m4_addr_i,      //core1 instr端口读/写请求地址
    output  logic   [31:0]  m4_rd_data_o,   //core1 instr端口读数据
    input   wire            m4_wr_en_i,     //core1 instr端口写使能
    input   wire    [31:0]  m4_wr_data_i,   //core1 instr端口写数据

    //master5 分给core1的scalar接口，负责从外部存储读取标量操作数，不需要向外部进行写入操作
    input   wire            m5_data_req_i,  //core1 scalar端口读请求
    input   wire    [31:0]  m5_addr_i,      //core1 scalar端口读/写请求地址
    output  logic   [31:0]  m5_rd_data_o,   //core1 scalar端口读数据
    input   wire            m5_wr_en_i,     //core1 scalar端口写使能
    input   wire    [31:0]  m5_wr_data_i,   //core1 scalar端口写数据

    //slave0 分给用于存储稀疏数据和稠密数据的外部存储接口
    output  logic           s0_data_req_o,  //外部存储读请求
    output  logic   [31:0]  s0_addr_o,      //外部存储读/写请求地址
    input   logic   [31:0]  s0_rd_data_i,   //外部存储读数据
    output  logic           s0_wr_en_o,     //外部存储写使能
    output  logic   [31:0]  s0_wr_data_o,   //外部存储写数据

    //slave1 分给用于存储instr的NVM
    output  logic           s1_data_req_o,  //NVM1读请求
    output  logic   [31:0]  s1_addr_o,      //NVM1读/写请求地址
    input   logic   [31:0]  s1_rd_data_i,   //NVM1读数据
    output  logic           s1_wr_en_o,     //NVM1写使能
    output  logic   [31:0]  s1_wr_data_o,   //NVM1写数据

    //slave2 分给用于存储scalar的NVM
    output  logic           s2_data_req_o,  //NVM2读请求
    output  logic   [31:0]  s2_addr_o,      //NVM2读/写请求地址
    input   logic   [31:0]  s2_rd_data_i,   //NVM2读数据
    output  logic           s2_wr_en_o,     //NVM2写使能
    output  logic   [31:0]  s2_wr_data_o    //NVM2写数据
);
    localparam MASTER0_ID = 3'b000; //分配给master0的id
    localparam MASTER1_ID = 3'b001; //分配给master1的id
    localparam MASTER2_ID = 3'b010; //分配给master2的id
    localparam MASTER3_ID = 3'b011; //分配给master3的id
    localparam MASTER4_ID = 3'b100; //分配给master4的id
    localparam MASTER5_ID = 3'b101; //分配给master5的id


    logic m0_hold_r = 0;
    logic m3_hold_r = 1;
    logic core_0_req = 0;
    logic core_1_req = 0;
    logic core_id = 0;
    
    `define CORE_0 = 0;
    `define CORE_1 = 1;
    
    always_comb begin
        core_0_req = m0_data_req_i || m1_data_req_i;
        core_1_req = m3_data_req_i || m4_data_req_i;
    end
    // 轮询仲裁器
    logic [2:0] core_data_id, next_core_data_id;
    logic [2:0] core_instr_id, next_core_instr_id;
    logic data_grant, instr_grant;

    // data端口轮询
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            core_data_id <= MASTER0_ID;
        end else if (data_grant) begin
            core_data_id <= next_core_data_id;
        end
    end

    always_comb begin
        data_grant = 1'b0;
        next_core_data_id = core_data_id;
        case (core_data_id)
            MASTER0_ID: begin
                if (m0_data_req_i) begin
                    data_grant = 1'b1;
                    next_core_data_id = MASTER0_ID;
                end else if (m3_data_req_i) begin
                    data_grant = 1'b1;
                    next_core_data_id = MASTER3_ID;
                end
            end
            MASTER3_ID: begin
                if (m3_data_req_i) begin
                    data_grant = 1'b1;
                    next_core_data_id = MASTER3_ID;
                end else if (m0_data_req_i) begin
                    data_grant = 1'b1;
                    next_core_data_id = MASTER0_ID;
                end
            end
            default: begin
                next_core_data_id = MASTER0_ID;
            end
        endcase
    end

    // instr端口轮询
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            core_instr_id <= MASTER1_ID;
        end else if (instr_grant) begin
            core_instr_id <= next_core_instr_id;
        end
    end

    always_comb begin
        instr_grant = 1'b0;
        next_core_instr_id = core_instr_id;
        case (core_instr_id)
            MASTER1_ID: begin
                if (core_0_req) begin
                    instr_grant = 1'b1;
                    next_core_instr_id = MASTER1_ID;
                end else if (core_1_req) begin
                    instr_grant = 1'b1;
                    next_core_instr_id = MASTER4_ID;
                end else begin
                    next_core_instr_id = next_core_instr_id;
                end
            end
            MASTER4_ID: begin
                if (core_1_req) begin
                    instr_grant = 1'b1;
                    next_core_instr_id = MASTER4_ID;
                end else if (core_0_req) begin
                    instr_grant = 1'b1;
                    next_core_instr_id = MASTER1_ID;
                end else begin
                    next_core_instr_id = next_core_instr_id;
                end
            end
            default: begin
                next_core_instr_id = MASTER1_ID;
                instr_grant = 1'b0;
            end
        endcase
    end

// m0_hold_o 和 m3_hold_o 信号配置
// 当当前仲裁到的不是自己，且自己有请求时，拉高hold信号
//always_ff @(posedge clk) begin
//    // m0: 只有当core_data_id不是MASTER0_ID且有请求时hold
//    if(core_0_req && core_1_req) begin
//        if ((core_instr_id == MASTER1_ID) && core_0_req && core_1_req) begin
//            m0_hold_r <= 1'b0;
//            m3_hold_r <= 1'b1;
//        end else if ((core_instr_id == MASTER4_ID) && core_1_req && core_0_req) begin
//            m3_hold_r <= 1'b0;
//            m0_hold_r <= 1'b1;
//        end
//    end else begin
//        if (!core_0_req && core_1_req && core_1_bus_spare)begin
//            m0_hold_r <= '0;
//            m3_hold_r <= '0;
//        end else if (!core_1_req && core_0_req && core_0_bus_spare)begin
//            m0_hold_r <= '0;
//            m3_hold_r <= '0;
//        end else begin
//            m0_hold_r <= m0_hold_r;
//            m3_hold_r <= m3_hold_r;
//        end
//    end
//end


assign m0_hold_o = m0_hold_r;
assign m3_hold_o = m3_hold_r;

//always_ff @(posedge clk or negedge rstn) begin
//    if(!rstn) begin
//        m0_hold_r <= '1;
//        m3_hold_r <= '1;
//    end else begin
//        if(!core_0_bus_spare) begin
//            m3_hold_r <= 1'b1;
//            m0_hold_r <= 1'b0;
//        end else if(!core_1_bus_spare) begin
//            m3_hold_r <= 1'b0;
//            m0_hold_r <= 1'b1;
//        end else begin
//            if(core_0_req && core_1_req) begin
//                m3_hold_r <= 1'b1;
//                m0_hold_r <= 1'b0;
//            end else begin
//                m3_hold_r <= !core_0_req;
//                m0_hold_r <= !core_1_req;
//            end
//        end
//    end
//end

logic core_0_req_r;
logic core_1_req_r;
always_ff @(posedge clk or negedge rstn) begin
    if(!rstn) begin
        core_0_req_r <= '0;
        core_1_req_r <= '0;
    end else begin
        core_0_req_r <= core_0_req;
        core_1_req_r <= core_1_req;
    end
end

logic core_0_bus_spare_r;
logic core_1_bus_spare_r;
always_ff @(posedge clk or negedge rstn) begin
    if(~rstn) begin
        core_0_bus_spare_r <= 1'b0;
        core_1_bus_spare_r <= 1'b0;
    end else begin
        core_0_bus_spare_r <= core_0_bus_spare;
        core_1_bus_spare_r <= core_1_bus_spare;
    end
end

always_comb begin
    if(!core_0_bus_spare && core_0_bus_spare_r) begin
        m0_hold_r = 1'b0;
        m3_hold_r = 1'b1;
    end else if(!core_0_bus_spare_r && core_0_bus_spare) begin
        m0_hold_r = 1'b1;
        m3_hold_r = 1'b0;
    end else if(!core_1_bus_spare && core_1_bus_spare_r) begin
        m0_hold_r = 1'b1;
        m3_hold_r = 1'b0;
    end else if(!core_1_bus_spare_r && core_1_bus_spare) begin
        m0_hold_r = 1'b0;
        m3_hold_r = 1'b1;
    //end else if(core_0_bus_spare && core_0_req_r && !core_0_req) begin
    //    m0_hold_r = 1'b1;
    //    m3_hold_r = 1'b0;
    //end else if(core_1_bus_spare && core_1_req_r && !core_1_req) begin
    //    m0_hold_r = 1'b0;
    //    m3_hold_r = 1'b1;
    //end else if(core_0_bus_spare && core_1_bus_spare && core_1_req) begin
    //    m0_hold_r = 1'b1;
    //    m3_hold_r = 1'b0;
    end else begin
        m0_hold_r = m0_hold_r;
        m3_hold_r = m3_hold_r;
    end
end

always_comb begin
    if(core_0_req) begin
        s0_data_req_o = m0_data_req_i;
        s0_addr_o = m0_addr_i;
        s0_wr_en_o = m0_wr_en_i;
        s0_wr_data_o = m0_wr_data_i;
        m0_rd_data_o = s0_rd_data_i;
        m3_rd_data_o = 32'h0000_0000;
        s1_data_req_o = m1_data_req_i;
        s1_addr_o = m1_addr_i;
        s1_wr_en_o = m1_wr_en_i;
        s1_wr_data_o = m1_wr_data_i;
        m1_rd_data_o = s1_rd_data_i;
        s2_data_req_o = m2_data_req_i;
        s2_addr_o = m2_addr_i;
        s2_wr_en_o = m2_wr_en_i;
        s2_wr_data_o = m2_wr_data_i;
        m2_rd_data_o = s2_rd_data_i;
        m4_rd_data_o = 32'h0000_0000;
        m5_rd_data_o = 32'h0000_0000;
    end else if (core_1_req && !core_0_req) begin
        s0_data_req_o = m3_data_req_i;
        s0_addr_o = m3_addr_i;
        s0_wr_en_o = m3_wr_en_i;
        s0_wr_data_o = m3_wr_data_i;
        m3_rd_data_o = s0_rd_data_i;
        m0_rd_data_o = 32'h0000_0000;
        s1_data_req_o = m4_data_req_i;
        s1_addr_o = m4_addr_i;
        s1_wr_en_o = m4_wr_en_i;
        s1_wr_data_o = m4_wr_data_i;
        m4_rd_data_o = s1_rd_data_i;
        s2_data_req_o = m5_data_req_i;
        s2_addr_o = m5_addr_i;
        s2_wr_en_o = m5_wr_en_i;
        s2_wr_data_o = m5_wr_data_i;
        m5_rd_data_o = s2_rd_data_i;
        m1_rd_data_o = 32'h0000_0000;
        m2_rd_data_o = 32'h0000_0000;
    end else begin
        s0_data_req_o = 1'b0;
        s0_addr_o = 32'h0000_0000;
        s0_wr_en_o = 1'b0;
        s0_wr_data_o = 32'h0000_0000;
        m0_rd_data_o = 32'h0000_0000;
        m3_rd_data_o = 32'h0000_0000;
        s1_data_req_o = 1'b0;
        s1_addr_o = 32'h0000_0000;
        s1_wr_en_o = 1'b0;
        s1_wr_data_o = 32'h0000_0000;
        m1_rd_data_o = 32'h0000_0000;

        s2_data_req_o = 1'b0;
        s2_addr_o = 32'h0000_0000;
        s2_wr_en_o = 1'b0;
        s2_wr_data_o = 32'h0000_0000;
        m2_rd_data_o = 32'h0000_0000;

        m4_rd_data_o = 32'h0000_0000;
        m5_rd_data_o = 32'h0000_0000;
    end
end




    //总线内部连接，采用部分连接，实现instr和data的同步传输，不必发生冲突
    //由于slave内部还存在延迟，因此这里使用组合逻辑
    //always_comb begin
    //    case(core_id)  
    //        MASTER1_ID: begin
    //            if(!core_0_bus_spare) begin
    //                s0_data_req_o = m0_data_req_i;
    //                s0_addr_o = m0_addr_i;
    //                s0_wr_en_o = m0_wr_en_i;
    //                s0_wr_data_o = m0_wr_data_i;
    //                m0_rd_data_o = s0_rd_data_i;
    //                m3_rd_data_o = 32'h0000_0000;
    //                s1_data_req_o = m1_data_req_i;
    //                s1_addr_o = m1_addr_i;
    //                s1_wr_en_o = m1_wr_en_i;
    //                s1_wr_data_o = m1_wr_data_i;
    //                m1_rd_data_o = s1_rd_data_i;
//
    //                s2_data_req_o = m2_data_req_i;
    //                s2_addr_o = m2_addr_i;
    //                s2_wr_en_o = m2_wr_en_i;
    //                s2_wr_data_o = m2_wr_data_i;
    //                m2_rd_data_o = s2_rd_data_i;
//
    //                m4_rd_data_o = 32'h0000_0000;
    //                m5_rd_data_o = 32'h0000_0000;
    //            end else begin
    //                s0_data_req_o = m3_data_req_i;
    //                s0_addr_o = m3_addr_i;
    //                s0_wr_en_o = m3_wr_en_i;
    //                s0_wr_data_o = m3_wr_data_i;
    //                m3_rd_data_o = s0_rd_data_i;
    //                m0_rd_data_o = 32'h0000_0000;
    //                s1_data_req_o = m4_data_req_i;
    //                s1_addr_o = m4_addr_i;
    //                s1_wr_en_o = m4_wr_en_i;
    //                s1_wr_data_o = m4_wr_data_i;
    //                m4_rd_data_o = s1_rd_data_i;
//
    //                s2_data_req_o = m5_data_req_i;
    //                s2_addr_o = m5_addr_i;
    //                s2_wr_en_o = m5_wr_en_i;
    //                s2_wr_data_o = m5_wr_data_i;
    //                m5_rd_data_o = s2_rd_data_i;
//
    //                m1_rd_data_o = 32'h0000_0000;
    //                m2_rd_data_o = 32'h0000_0000;
    //            end
    //        end
    //        MASTER4_ID: begin
    //            if(!core_1_bus_spare) begin
    //                s0_data_req_o = m3_data_req_i;
    //                s0_addr_o = m3_addr_i;
    //                s0_wr_en_o = m3_wr_en_i;
    //                s0_wr_data_o = m3_wr_data_i;
    //                m3_rd_data_o = s0_rd_data_i;
    //                m0_rd_data_o = 32'h0000_0000;
    //                s1_data_req_o = m4_data_req_i;
    //                s1_addr_o = m4_addr_i;
    //                s1_wr_en_o = m4_wr_en_i;
    //                s1_wr_data_o = m4_wr_data_i;
    //                m4_rd_data_o = s1_rd_data_i;
//
    //                s2_data_req_o = m5_data_req_i;
    //                s2_addr_o = m5_addr_i;
    //                s2_wr_en_o = m5_wr_en_i;
    //                s2_wr_data_o = m5_wr_data_i;
    //                m5_rd_data_o = s2_rd_data_i;
//
    //                m1_rd_data_o = 32'h0000_0000;
    //                m2_rd_data_o = 32'h0000_0000;
    //            end else begin
    //                s0_data_req_o = m0_data_req_i;
    //                s0_addr_o = m0_addr_i;
    //                s0_wr_en_o = m0_wr_en_i;
    //                s0_wr_data_o = m0_wr_data_i;
    //                m0_rd_data_o = s0_rd_data_i;
    //                m3_rd_data_o = 32'h0000_0000;
    //                s1_data_req_o = m1_data_req_i;
    //                s1_addr_o = m1_addr_i;
    //                s1_wr_en_o = m1_wr_en_i;
    //                s1_wr_data_o = m1_wr_data_i;
    //                m1_rd_data_o = s1_rd_data_i;
//
    //                s2_data_req_o = m2_data_req_i;
    //                s2_addr_o = m2_addr_i;
    //                s2_wr_en_o = m2_wr_en_i;
    //                s2_wr_data_o = m2_wr_data_i;
    //                m2_rd_data_o = s2_rd_data_i;
//
    //                m4_rd_data_o = 32'h0000_0000;
    //                m5_rd_data_o = 32'h0000_0000;
    //            end
    //        end
    //        default: begin
    //            s0_data_req_o = 1'b0;
    //            s0_addr_o = 32'h0000_0000;
    //            s0_wr_en_o = 1'b0;
    //            s0_wr_data_o = 32'h0000_0000;
    //            m0_rd_data_o = 32'h0000_0000;
    //            m3_rd_data_o = 32'h0000_0000;
    //            s1_data_req_o = 1'b0;
    //            s1_addr_o = 32'h0000_0000;
    //            s1_wr_en_o = 1'b0;
    //            s1_wr_data_o = 32'h0000_0000;
    //            m1_rd_data_o = 32'h0000_0000;
//
    //            s2_data_req_o = 1'b0;
    //            s2_addr_o = 32'h0000_0000;
    //            s2_wr_en_o = 1'b0;
    //            s2_wr_data_o = 32'h0000_0000;
    //            m2_rd_data_o = 32'h0000_0000;
//
    //            m4_rd_data_o = 32'h0000_0000;
    //            m5_rd_data_o = 32'h0000_0000;
    //        end
    //    endcase
    //end

    //always_comb begin
    //    case(core_instr_id)
    //        MASTER1_ID: begin
    //            s1_data_req_o = m1_data_req_i;
    //            s1_addr_o = m1_addr_i;
    //            s1_wr_en_o = m1_wr_en_i;
    //            s1_wr_data_o = m1_wr_data_i;
    //            m1_rd_data_o = s1_rd_data_i;
//
    //            s2_data_req_o = m2_data_req_i;
    //            s2_addr_o = m2_addr_i;
    //            s2_wr_en_o = m2_wr_en_i;
    //            s2_wr_data_o = m2_wr_data_i;
    //            m2_rd_data_o = s2_rd_data_i;
//
    //            m4_rd_data_o = 32'h0000_0000;
    //            m5_rd_data_o = 32'h0000_0000;
    //        end
    //        MASTER4_ID: begin
    //            s1_data_req_o = m4_data_req_i;
    //            s1_addr_o = m4_addr_i;
    //            s1_wr_en_o = m4_wr_en_i;
    //            s1_wr_data_o = m4_wr_data_i;
    //            m4_rd_data_o = s1_rd_data_i;
//
    //            s2_data_req_o = m5_data_req_i;
    //            s2_addr_o = m5_addr_i;
    //            s2_wr_en_o = m5_wr_en_i;
    //            s2_wr_data_o = m5_wr_data_i;
    //            m5_rd_data_o = s2_rd_data_i;
//
    //            m1_rd_data_o = 32'h0000_0000;
    //            m2_rd_data_o = 32'h0000_0000;
    //        end
    //        default: begin
    //            s1_data_req_o = 1'b0;
    //            s1_addr_o = 32'h0000_0000;
    //            s1_wr_en_o = 1'b0;
    //            s1_wr_data_o = 32'h0000_0000;
    //            m1_rd_data_o = 32'h0000_0000;
//
    //            s2_data_req_o = 1'b0;
    //            s2_addr_o = 32'h0000_0000;
    //            s2_wr_en_o = 1'b0;
    //            s2_wr_data_o = 32'h0000_0000;
    //            m2_rd_data_o = 32'h0000_0000;
//
    //            m4_rd_data_o = 32'h0000_0000;
    //            m5_rd_data_o = 32'h0000_0000;
    //        end
    //    endcase
    //end
        

endmodule
