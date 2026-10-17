// A bouncing ball. Each step pulse it moves XSPEED pixels sideways and SPEED pixels up or down,
// and it bounces off the walls and the paddle.
// If it reaches the paddle row and the paddle is not under it, miss pulses and the ball restarts
// from the start position, moving right and down.
`default_nettype none

module ip_ball #(
    parameter W      = 640,
    parameter SIZE   = 8,
    parameter SPEED  = 2,    // pixels up or down on each step
    parameter XSPEED = 1,    // pixels sideways on each step
    parameter PY     = 448,
    parameter PW     = 64
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       step,
    input  wire [9:0] paddle_x,
    output reg  [9:0] x,
    output reg  [9:0] y,
    output reg        miss
);
    reg right;   // 1 = moving right
    reg down;    // 1 = moving down

    wire over_paddle = (x + SIZE > paddle_x) && (x < paddle_x + PW);

    always @(posedge clk) begin
        miss <= 1'b0;
        if (!rst_n) begin
            x     <= (W - SIZE) / 2;
            y     <= PY / 4;
            right <= 1'b1;
            down  <= 1'b1;
        end else if (step) begin
            // sideways
            if (right) begin
                if (x + XSPEED + SIZE >= W) right <= 1'b0;
                else                        x <= x + XSPEED;
            end else begin
                if (x <= XSPEED) right <= 1'b1;
                else             x <= x - XSPEED;
            end
            // up and down
            if (down) begin
                if (y + SPEED + SIZE >= PY) begin
                    if (over_paddle) begin
                        down <= 1'b0;
                    end else begin
                        // missed: start again, in the same state as after reset
                        miss  <= 1'b1;
                        x     <= (W - SIZE) / 2;
                        y     <= PY / 4;
                        right <= 1'b1;
                        down  <= 1'b1;
                    end
                end else begin
                    y <= y + SPEED;
                end
            end else begin
                if (y <= SPEED) down <= 1'b1;
                else            y <= y - SPEED;
            end
        end
    end
endmodule
