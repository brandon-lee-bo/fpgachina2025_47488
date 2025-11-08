// rvv_pkg.sv
// 功能：定义 RISC-V 向量处理器的全局参数、宏定义和枚举类型
// 用于 riscv_core 及其子模块 vex, vlsu, vid 等的统一接口

`ifndef RVV_PKG_SV
`define RVV_PKG_SV

package rvv_pkg;

// 宽度宏定义
`define InstAddrBus     31:0    // 指令地址总线宽度（32 位）
`define InstBus         31:0    // 指令总线宽度（32 位）
`define RegAddrBus      4:0     // 向量寄存器地址总线宽度（5 位，支持 32 个寄存器）
`define MemAddrBus      31:0    // 内存地址总线宽度（32 位，与 AXI 兼容）
`define MemBus          31:0    // 内存数据总线宽度（32 位，向量寄存器宽度32*4）
`define VLENB           32'd16  // 向量寄存器长度（16 字节，即 128 位）
`define VL_WIDTH        6:0     // 向量长度（vl）宽度（7 位，支持最大 128 元素）
`define VSEW_WIDTH      2:0     // 向量元素宽度（vsew）宽度（3 位）
`define VLMUL_WIDTH     2:0     // 向量长度乘数（vlmul）宽度（3 位）
`define PC_INIT         32'h0000_0000   // PC 初始地址
`define INST_WIDTH      32'h4   // 指令宽度（4 字节）

// ctrl 模块相关宏定义
`define HOLD_VLSU_BIT   3       // 控制 vlsu 暂停的位
`define HOLD_VEX_BIT    2       // 控制 vex 暂停的位
`define HOLD_VID_BIT    1       // 控制 vid 暂停的位
`define HOLD_PC_BIT     0       // 控制 pc_reg 暂停的位
`define HOLD_ENABLE     1'b1    // 暂停使能值（高有效）
`define HOLD_DISABLE    1'b0    // 暂停禁用值（低电平）

// vid 模块相关宏定义
`define V_OPCFG         3'b000  // 向量配置指令的 funct3 值（用于 vsetvli）

// 枚举类型定义

// 运算类型（用于 vex 和 lane 模块的 pe_op）
typedef enum logic [3:0] {
    PE_ARITH_ADD        = 4'b0000,   // 向量加法
    PE_SPMM_COMPUTE     = 4'b0100,   // SPMM 计算（新增，用于执行spmm计算）
    PE_SPMM_LOAD_DENSE  = 4'b0101,   // SPMM 加载（新增，用于加载稀疏矩阵数据）
    PE_SPMM_CAL_INDEX   = 4'b0110,   // SPMM 计算行索引（新增，用于计算行索引）
    PE_SPMM_FIX_ROW     = 4'b0111,    // SPMM 固定行索引（新增，用于固定当前行索引）
    PE_SPMM_LOAD_TMP    = 4'b1000
} pe_arith_op_t;

// 操作数选择（用于 vex 和 vid 模块的 operand_select）
typedef enum logic [1:0] {
    PE_OPERAND_VS1      = 2'b00,    // 操作数来自 VS1 寄存器
    PE_OPERAND_SCALAR   = 2'b01,    // 操作数来自标量
    PE_OPERAND_IMMEDIATE= 2'b10,     // 操作数来自立即数
    PE_OPERAND_CSR      = 2'b11     // 操作数来自 CSR 寄存器（如 vcsr）
} pe_operand_t;

// 目标寄存器数据来源（用于 vid 和 vrf 模块的 vd_data_src）
typedef enum logic [1:0] {
    VREG_WB_SRC_MEMORY  = 2'b00,    // 数据来自内存（vlsu）
    VREG_WB_SRC_ARITH   = 2'b01,    // 数据来自算术运算结果（vex）
    VREG_WB_SRC_SCALAR  = 2'b10,     // 数据来自标量复制结果（vex）
    VREG_WB_SRC_ARITH_LANE = 2'b11
} vreg_wb_src_t;

// 第三源寄存器地址来源（用于 vid 和 vrf 模块的 vs3_addr_src）
typedef enum logic [1:0] {
    VS3_ADDR_SRC_DECODE = 2'b00,    // 地址来自解码阶段（vid）
    VS3_ADDR_SRC_VLSU   = 2'b01     // 地址来自 vlsu
} vreg_addr_src_t;

// vid 模块中 funct3 的定义（用于区分向量操作类型）
typedef enum logic [2:0] {
    V_OPIVV = 3'b000,   // 向量-向量运算
    V_OPIVX = 3'b001,   // 向量-标量运算
    V_OPMVV = 3'b010,   // 向量-向量乘法
    V_OPMVX = 3'b011    // 向量-标量乘法
} vid_funct3_t;

endpackage

`endif