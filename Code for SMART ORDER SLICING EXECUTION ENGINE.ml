(* =============================================================================
   SMART ORDER EXECUTION ENGINE (TRADE SLICING) - OCaml Edition
   -----------------------------------------------------------------------------
   DEFAULT: Simulation mode (runs instantly, no external libraries).
   PRODUCTION: Fully self-contained block at the bottom (no external libs either).
               See instructions at the end of this file to enable.
   ============================================================================= *)

(* ==================== CONFIGURATION ==================== *)
let parent_order_qty  = 100_000
let tick_interval_sec = 0.5
let simulation_ticks  = 40
let horizon_seconds   = 60.0

(* ==================== UTILITIES ==================== *)
let gaussian () =
  let u1 = Random.float 1.0 +. 1e-9 in
  let u2 = Random.float 1.0 in
  sqrt (-2.0 *. log u1) *. cos (2.0 *. Float.pi *. u2)

let center s width =
  let len = String.length s in
  if len >= width then s
  else
    let pad   = width - len in
    let left  = pad / 2 in
    let right = pad - left in
    String.make left ' ' ^ s ^ String.make right ' '

let round_to x places =
  let m = 10.0 ** float_of_int places in
  floor (x *. m +. 0.5) /. m

let rec take n lst =
  if n <= 0 then []
  else match lst with
    | []      -> []
    | x :: xs -> x :: take (n - 1) xs

(* ==================== MOCK CLOCK (replaces Unix) ==================== *)
module Clock = struct
  let current_time = ref 0.0
  let tick ()      = current_time := !current_time +. tick_interval_sec
  let now ()       = !current_time
  let format_time ts =
    let total = int_of_float ts in
    let h = 9  + (total / 3600) in
    let m = 30 + ((total / 60) mod 60) in
    let s = total mod 60 in
    Printf.sprintf "%02d:%02d:%02d" h m s
end

(* ==================== TYPES ==================== *)
type market_condition = Preferred | Good | Fair | Poor | Worst

let condition_to_string = function
  | Preferred -> "PREFERRED"
  | Good      -> "GOOD"
  | Fair      -> "FAIR"
  | Poor      -> "POOR"
  | Worst     -> "WORST"

let all_conditions = [Preferred; Good; Fair; Poor; Worst]

type market_tick = {
  timestamp        : float;
  price            : float;
  bid              : float;
  ask              : float;
  volume_24h       : float;
  order_book_depth : float;
}

type execution_slice = {
  tick_time         : float;
  condition         : market_condition;
  slice_qty         : int;
  fill_price        : float;
  slippage_bps      : float;
  cumulative_filled : int;
  slice_remaining   : int;   (* renamed to avoid clash with engine field *)
}

(* ==================== MARKET SIMULATOR ==================== *)
module MarketSimulator = struct
  type t = {
    mutable price      : float;
    volatility         : float;
    mean               : float;
    mutable spread_bps : float;
  }

  let create start_price = {
    price      = start_price;
    volatility = 0.002;
    mean       = start_price;
    spread_bps = 2.0;
  }

  let next_tick s =
    let drift = (s.mean -. s.price) *. 0.05 in
    let shock = gaussian () *. s.volatility *. s.price in
    s.price <- s.price +. drift +. shock;
    s.price <- Float.max s.price 10.0;

    s.spread_bps <- s.spread_bps +. (Random.float 1.3 -. 0.5);
    s.spread_bps <- Float.max 1.0 (Float.min 25.0 s.spread_bps);

    let spread_amount = (s.spread_bps /. 10000.0) *. s.price in
    let bid = s.price -. spread_amount /. 2.0 in
    let ask = s.price +. spread_amount /. 2.0 in

    let depth_factor =
      Float.max 0.2 (Float.min 1.8 (30.0 /. (s.spread_bps +. 2.0)))
    in
    let depth  = 5000.0 *. depth_factor +. (Random.float 2000.0 -. 1000.0) in
    let volume = 1_500_000.0 *. (0.8 +. 0.4 *. Random.float 1.0) in

    {
      timestamp        = Clock.now ();
      price            = round_to s.price 2;
      bid              = round_to bid 2;
      ask              = round_to ask 2;
      volume_24h       = Float.round volume;
      order_book_depth = Float.round (Float.max 500.0 depth);
    }
end

(* ==================== CONDITION ANALYZER ==================== *)
module ConditionAnalyzer = struct
  type t = {
    mutable price_history : float list;
    window_size           : int;
  }

  let create window_size = { price_history = []; window_size }

  let analyze a tick =
    a.price_history <- tick.price :: a.price_history;
    a.price_history <- take a.window_size a.price_history;

    let spread_bps = (tick.ask -. tick.bid) /. tick.price *. 10000.0 in
    let spread_score =
      Float.max 0.0 (Float.min 100.0 (100.0 -. spread_bps *. 4.0))
    in

    let recent5 = take 5 a.price_history in
    let std =
      if List.length recent5 >= 5 then begin
        let n = float_of_int (List.length recent5) in
        let mean_p = List.fold_left (+.) 0.0 recent5 /. n in
        let var =
          List.fold_left
            (fun acc p -> acc +. (p -. mean_p) ** 2.0) 0.0 recent5 /. n
        in
        sqrt var /. tick.price *. 10000.0
      end else 10.0
    in
    let vol_score   = Float.max 0.0 (Float.min 100.0 (100.0 -. std *. 2.0)) in
    let depth_score = Float.min 100.0 (tick.order_book_depth /. 5000.0 *. 100.0) in
    let total_score =
      spread_score *. 0.5 +. vol_score *. 0.3 +. depth_score *. 0.2
    in

    if      total_score >= 80.0 then Preferred
    else if total_score >= 65.0 then Good
    else if total_score >= 45.0 then Fair
    else if total_score >= 25.0 then Poor
    else Worst
end

(* ==================== PHYSICAL ACTION MAPPER (SIMULATION) ==================== *)
module PhysicalActionMapper = struct
  let execute_action condition _tick_price =
    print_newline ();
    print_endline ("[PIN] " ^ String.make 50 '-');
    Printf.printf "PHYSICAL ACTION TRIGGERED (Condition: %s)\n"
      (condition_to_string condition);

    let speed, gpio_pin, alert_light =
      match condition with
      | Preferred -> ("100% (FULL SPEED)",  "PIN 12 (ON)",                  "GREEN (Safe)")
      | Good      -> ("80% (FAST)",         "PIN 12 (ON)",                  "GREEN (Safe)")
      | Fair      -> ("50% (MODERATE)",     "PIN 12 (ON) - PIN 13 (OFF)",   "YELLOW (Caution)")
      | Poor      -> ("20% (SLOW)",         "PIN 12 (OFF) - PIN 13 (PWM 30%)", "ORANGE (Warning)")
      | Worst     -> ("0% (EMERGENCY STOP)","ALL PINS OFF (Safety Lock)",   "RED (Critical / HALT)")
    in
    Printf.printf "   Speed Command : %s\n" speed;
    Printf.printf "   GPIO Control  : %s\n" gpio_pin;
    Printf.printf "   Alert Status  : %s\n" alert_light;
    print_endline (String.make 52 '-')
end

(* ==================== SMART EXECUTION ENGINE ==================== *)
module SmartExecutionEngine = struct
  type t = {
    parent_qty            : int;
    mutable remaining_qty : int;
    horizon_sec           : float;
    mutable total_filled  : int;
    mutable total_cost    : float;
    mutable slices        : execution_slice list;
    analyzer              : ConditionAnalyzer.t;
    start_time            : float;
  }

  let create parent_qty horizon_sec = {
    parent_qty    = parent_qty;
    remaining_qty = parent_qty;
    horizon_sec   = horizon_sec;
    total_filled  = 0;
    total_cost    = 0.0;
    slices        = [];
    analyzer      = ConditionAnalyzer.create 10;
    start_time    = Clock.now ();
  }

  let condition_multiplier = function
    | Preferred -> 1.8
    | Good      -> 1.3
    | Fair      -> 1.0
    | Poor      -> 0.5
    | Worst     -> 0.0

  let process_tick e tick =
    let condition = ConditionAnalyzer.analyze e.analyzer tick in
    if e.remaining_qty <= 0 then None
    else begin
      let elapsed = Clock.now () -. e.start_time in
      let expected_ticks_remaining =
        Float.max 1.0 ((e.horizon_sec -. elapsed) /. tick_interval_sec)
      in
      let base_qty =
        int_of_float
          (Float.max 1.0
             (float_of_int e.remaining_qty /. expected_ticks_remaining))
      in
      let multiplier = condition_multiplier condition in
      let slice_qty  = int_of_float (float_of_int base_qty *. multiplier) in
      let slice_qty  = min slice_qty e.remaining_qty in

      let mid = (tick.bid +. tick.ask) /. 2.0 in
      let base_slippage_bps = 0.5 +. Random.float 1.5 in
      let condition_penalty =
        match condition with
        | Worst -> 5.0
        | Poor  -> 2.0
        | _     -> 0.0
      in
      let size_impact =
        (float_of_int slice_qty /. float_of_int e.parent_qty) *. 3.0
      in
      let total_slippage_bps =
        base_slippage_bps +. condition_penalty +. size_impact
      in
      let fill_price = mid *. (1.0 +. (total_slippage_bps /. 10000.0)) in

      e.remaining_qty <- e.remaining_qty - slice_qty;
      e.total_filled  <- e.total_filled + slice_qty;
      e.total_cost    <- e.total_cost +. float_of_int slice_qty *. fill_price;

      let slice_rec = {
        tick_time         = tick.timestamp;
        condition         = condition;
        slice_qty         = slice_qty;
        fill_price        = round_to fill_price 2;
        slippage_bps      = round_to total_slippage_bps 2;
        cumulative_filled = e.total_filled;
        slice_remaining   = e.remaining_qty;
      } in
      e.slices <- slice_rec :: e.slices;
      Some slice_rec
    end
end

(* ==================== PRINT HELPERS ==================== *)
let print_header () =
  print_newline ();
  print_endline (String.make 120 '=');
  print_endline "SMART ORDER EXECUTION ENGINE (TRADE SLICING) - LIVE FEED";
  print_endline (String.make 120 '=');
  Printf.printf "Parent Order: %d shares | Horizon: %.0fs | Ticks: %d\n"
    parent_order_qty horizon_seconds simulation_ticks;
  print_endline (String.make 120 '-');
  Printf.printf "%s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n"
    (center "Time" 10) (center "Price" 8) (center "Spread" 10)
    (center "Depth" 10) (center "Condition" 12) (center "Slice" 10)
    (center "Fill Price" 10) (center "Slippage" 10)
    (center "Filled" 10) (center "Remaining" 10);
  print_endline (String.make 120 '-')

let print_tick_output (tick : market_tick) (slice_rec : execution_slice) =
  let spread_bps = (tick.ask -. tick.bid) /. tick.price *. 10000.0 in
  let time_str   = Clock.format_time tick.timestamp in
  let cond_str   = condition_to_string slice_rec.condition in

  if slice_rec.slice_qty = 0 then
    Printf.printf
      "%s | %8.2f | %10.2f | %10.0f | %s | %s | %s | %s | %10d | %10d\n"
      (center time_str 10) tick.price spread_bps tick.order_book_depth
      (center cond_str 12) (center "PAUSED" 10) (center "-" 10) (center "-" 10)
      slice_rec.cumulative_filled slice_rec.slice_remaining
  else
    Printf.printf
      "%s | %8.2f | %10.2f | %10.0f | %s | %10d | %10.2f | %10.2f | %10d | %10d\n"
      (center time_str 10) tick.price spread_bps tick.order_book_depth
      (center cond_str 12) slice_rec.slice_qty slice_rec.fill_price
      slice_rec.slippage_bps slice_rec.cumulative_filled slice_rec.slice_remaining;

  PhysicalActionMapper.execute_action slice_rec.condition tick.price

let print_final_report (e : SmartExecutionEngine.t) =
  print_newline ();
  print_endline (String.make 120 '=');
  print_endline "FINAL EXECUTION SUMMARY & CONDITION BREAKDOWN";
  print_endline (String.make 120 '=');

  let avg_price =
    if e.SmartExecutionEngine.total_filled > 0
    then e.SmartExecutionEngine.total_cost
         /. float_of_int e.SmartExecutionEngine.total_filled
    else 0.0
  in
  let total_slippage_bps =
    match List.rev e.SmartExecutionEngine.slices with
    | first :: _ -> (avg_price /. first.fill_price -. 1.0) *. 10000.0
    | []         -> 0.0
  in
  Printf.printf "Total Filled : %d / %d shares\n"
    e.SmartExecutionEngine.total_filled parent_order_qty;
  Printf.printf "Avg Fill     : $%.4f\n" avg_price;
  Printf.printf "Total Slippage (vs first trade): %.2f bps\n" total_slippage_bps;
  Printf.printf "Exec Time    : %.2f seconds\n"
    (Clock.now () -. e.SmartExecutionEngine.start_time);

  print_endline "\nCondition Frequency:";
  let total = List.length e.SmartExecutionEngine.slices in
  List.iter (fun c ->
    let count =
      List.fold_left
        (fun a s -> if s.condition = c then a + 1 else a)
        0 e.SmartExecutionEngine.slices
    in
    let pct =
      if total > 0 then float_of_int count /. float_of_int total *. 100.0
      else 0.0
    in
    let bar = String.make (int_of_float (pct /. 2.0)) '#' in
    Printf.printf "  %-12s : %3d ticks (%5.1f%%) %s\n"
      (condition_to_string c) count pct bar
  ) all_conditions;

  print_endline "\nDetailed Slice Log:";
  print_endline (String.make 90 '-');
  Printf.printf "%s | %s | %s | %s | %s | %s\n"
    (center "Tick" 6) (center "Time" 10) (center "Condition" 12)
    (center "Slice Qty" 10) (center "Fill Price" 10) (center "Slippage" 10);
  print_endline (String.make 90 '-');

  List.iteri (fun i s ->
    Printf.printf "%s | %s | %s | %10d | %10.2f | %10.2f\n"
      (center (string_of_int (i + 1)) 6)
      (center (Clock.format_time s.tick_time) 10)
      (center (condition_to_string s.condition) 12)
      s.slice_qty s.fill_price s.slippage_bps
  ) (List.rev e.SmartExecutionEngine.slices);

  if e.SmartExecutionEngine.remaining_qty > 0 then
    Printf.printf "\nALERT: %d shares REMAIN unfilled.\n"
      e.SmartExecutionEngine.remaining_qty
  else
    print_endline "\nParent order fully executed."

(* ==================== SIMULATION LOOP ==================== *)
let run_simulation () =
  Random.self_init ();
  let sim    = MarketSimulator.create 152.30 in
  let engine = SmartExecutionEngine.create parent_order_qty horizon_seconds in

  print_header ();

  let rec loop i =
    if i >= simulation_ticks then ()
    else begin
      Clock.tick ();
      let tick = MarketSimulator.next_tick sim in
      (match SmartExecutionEngine.process_tick engine tick with
       | None           -> print_endline "\nOrder fully filled. Stopping early."
       | Some slice_rec -> print_tick_output tick slice_rec);
      loop (i + 1)
    end
  in
  loop 0;

  print_final_report engine

(* =============================================================================
   ============ DEFAULT ENTRY POINT: SIMULATION (runs by default) =============
   ============================================================================= *)
let () = run_simulation ()

(* =============================================================================
   ============ PRODUCTION MODE ================================================
   ============ INSTRUCTIONS TO ENABLE =========================================

     1. Comment out or delete the line ABOVE:  `let () = run_simulation ()`
     2. Uncomment this ENTIRE block (remove the leading  (*  on this line
        and the trailing  *)  at the very bottom of the block).

   After these 2 steps, run the program again. It will execute in production
   mode using the same engine, condition analyzer, and clock -- only the
   pipeline (mapper + loop) is different.

   =============================================================================

module ProductionActionMapper = struct
  let execute_action condition _tick_price =
    print_newline ();
    print_endline ("[PROD-PIN] " ^ String.make 50 '-');
    Printf.printf "PHYSICAL ACTION TRIGGERED (Condition: %s)\n"
      (condition_to_string condition);

    let speed, gpio_state, alert =
      match condition with
      | Preferred -> (100, "HIGH",    "GREEN")
      | Good      -> ( 80, "HIGH",    "GREEN")
      | Fair      -> ( 50, "PWM 50%", "YELLOW")
      | Poor      -> ( 20, "PWM 20%", "ORANGE")
      | Worst     -> (  0, "ALL OFF", "RED (EMERGENCY)")
    in
    Printf.printf "   Speed Command : %d%%\n" speed;
    Printf.printf "   GPIO Control  : %s\n"   gpio_state;
    Printf.printf "   Alert Status  : %s\n"   alert;
    print_endline (String.make 52 '-')
end

let run_production () =
  print_newline ();
  print_endline (String.make 120 '=');
  print_endline "SMART ORDER EXECUTION ENGINE - PRODUCTION MODE (Simulated Stream)";
  print_endline (String.make 120 '=');
  Printf.printf "Parent Order: %d shares | Max ticks: %d\n"
    parent_order_qty 100;
  print_endline (String.make 120 '-');

  Random.self_init ();
  let sim    = MarketSimulator.create 152.30 in
  let engine = SmartExecutionEngine.create parent_order_qty horizon_seconds in

  let max_prod_ticks = 100 in
  let rec loop i =
    if i >= max_prod_ticks then
      print_endline "\n[PROD] Max ticks reached. Shutting down stream."
    else if engine.SmartExecutionEngine.remaining_qty <= 0 then
      print_endline "\n[PROD] Order fully filled. Shutting down stream."
    else begin
      Clock.tick ();
      let tick = MarketSimulator.next_tick sim in
      (match SmartExecutionEngine.process_tick engine tick with
       | None -> ()
       | Some slice_rec ->
         ProductionActionMapper.execute_action slice_rec.condition tick.price;
         Printf.printf "[PROD] %s | Price: %8.2f | Cond: %-10s | Filled: %6d | Remaining: %6d\n"
           (Clock.format_time tick.timestamp)
           tick.price
           (condition_to_string slice_rec.condition)
           slice_rec.cumulative_filled
           slice_rec.slice_remaining);
      loop (i + 1)
    end
  in
  loop 0;

  print_final_report engine

let () = run_production ()

   ============================================================================= *)