-module(brazier_debug_ffi).
-export([process_count/0, memory_total/0, uptime_seconds/0]).

process_count() ->
    erlang:system_info(process_count).

memory_total() ->
    erlang:memory(total).

uptime_seconds() ->
    {Uptime, _} = erlang:statistics(wall_clock),
    Uptime div 1000.
