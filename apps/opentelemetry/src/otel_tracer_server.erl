%%%------------------------------------------------------------------------
%% Copyright 2019, OpenTelemetry Authors
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc This module is the SDK's implementation of the TracerProvider. The
%% calls to the server are done from the API module `otel_tracer_provider'.
%% This `gen_server' is started as part of the SDK's supervision tree and
%% registers itself as the default TracerProvider by using the name
%% `otel_tracer_provider' as its name.
%% @end
%%%-------------------------------------------------------------------------
-module(otel_tracer_server).

-behaviour(gen_server).

-export([start_link/4]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         code_change/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include("otel_tracer.hrl").
-include("otel_span.hrl").

-type instrumentation_scope() :: #instrumentation_scope{}.
-export_type([instrumentation_scope/0]).

-record(state,
        {
         %% the tracer configuration shared between all named
         %% tracers created by this provider
         shared_tracer :: tracer() | undefined,
         id_generator :: module(),
         processors :: [module()],
         sampler :: otel_sampler:t(),
         resource :: otel_resource:t(),

         span_processor_sup :: atom(),

         %% list of tracer names to return noop tracers for
         deny_list :: [atom() | {atom(), string()}]
        }).

-spec start_link(atom(), atom(), atom(), otel_configuration:t()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Name, RegName, SpanProcessorSupRegName, Config) ->
    gen_server:start_link({local, RegName}, ?MODULE, [Name, SpanProcessorSupRegName, Config], []).

init([Name, SpanProcessorSup, #{id_generator := IdGeneratorModule,
                                sampler := SamplerSpec,
                                processors := Processors,
                                deny_list := DenyList}]) ->
    Resource = otel_resource_detector:get_resource(),

    Sampler = otel_sampler:new(SamplerSpec),

    Processors1 = init_processors(SpanProcessorSup, Processors),

    Tracer = #tracer{module=otel_tracer_default,
                     sampler=Sampler,
                     on_start_processors=on_start(Processors1),
                     on_end_processors=on_end(Processors1),
                     id_generator=IdGeneratorModule},
    opentelemetry:set_default_tracer(Name, {otel_tracer_default, Tracer}),

    {ok, #state{id_generator=IdGeneratorModule,
                resource=Resource,
                sampler=Sampler,
                deny_list=DenyList,
                shared_tracer=Tracer,
                span_processor_sup=SpanProcessorSup,
                processors=Processors1}}.

handle_call(resource, _From, State=#state{resource=Resource}) ->
    {reply, Resource, State};
handle_call({get_tracer, _Name, _Vsn, _SchemaUrl}, _From, State=#state{shared_tracer=undefined}) ->
    {reply, {otel_tracer_noop, []}, State};
handle_call({get_tracer, Name, Vsn, SchemaUrl}, _From, State=#state{shared_tracer=Tracer,
                                                                    deny_list=DenyList}) ->
    %% TODO: support semver constraints in denylist
    case proplists:is_defined(Name, DenyList) of
        true ->
            {reply, {otel_tracer_noop, []}, State};
        false ->
            InstrumentationScope = opentelemetry:instrumentation_scope(Name, Vsn, SchemaUrl),
            TracerTuple = {Tracer#tracer.module,
                           Tracer#tracer{instrumentation_scope=InstrumentationScope}},
            {reply, TracerTuple, State}
    end;
handle_call({get_tracer, InstrumentationScope}, _From, State=#state{shared_tracer=Tracer,
                                                                      deny_list=_DenyList}) ->
    {reply, {Tracer#tracer.module,
             Tracer#tracer{instrumentation_scope=InstrumentationScope}}, State};
handle_call(force_flush, _From, State=#state{processors=Processors}) ->
    Reply = lists:foldl(fun(Processor, Result) ->
                                case force_flush_(Processor) of
                                    ok ->
                                        Result;
                                    {error, Reason} ->
                                        update_force_flush_error(Reason, Result)
                                end
                        end, ok, Processors),
    {reply, Reply, State}.

handle_cast(_, State) ->
    {noreply, State}.

code_change(State) ->
    {ok, State}.
%%

-spec update_force_flush_error(term(), ok | {error, list()}) -> {error, list()}.
update_force_flush_error(Reason, ok) ->
    {error, [Reason]};
update_force_flush_error(Reason, {error, List}) ->
    {error, [Reason | List]}.

init_processors(SpanProcessorSup, Processors) ->
    lists:filtermap(fun({P, Config}) ->
                            %% start_link is an optional callback for processors
                            case erlang:function_exported(P, start_link, 1) of
                                true ->
                                    try
                                        case supervisor:start_child(SpanProcessorSup, [P, Config]) of
                                            {ok, _Pid, Config1} ->
                                                {true, {P, Config1}};
                                            {error, Reason} ->
                                                ?LOG_INFO("Dropping span processor ~p because `processor_init/1` failed ~p", [P, Reason]),
                                                false
                                        end
                                    catch
                                        C:T:S ->
                                            ?LOG_DEBUG("Dropping span processor ~p because `processor_init/1` threw an exception ~p:~p:~p", [P, C, T, S]),
                                            ?LOG_INFO("Dropping span processor ~p because `processor_init/1` threw an exception ~p:~p", [P, C, T]),
                                            false
                                    end;
                                false ->
                                    {true, {P, Config}}
                            end
                    end, Processors).

on_start(Processors) ->
    fun(Ctx, Span) ->
            lists:foldl(fun({P, Config}, Acc) ->
                                P:on_start(Ctx, Acc, Config)
                        end, Span, Processors)
    end.

on_end(Processors) ->
    fun(Span) ->
            lists:foldl(fun({P, Config}, Bool) ->
                                Bool andalso P:on_end(Span, Config)
                        end, true, Processors)
    end.

force_flush_({Processor, Config}) ->
    try
        Processor:force_flush(Config)
    catch
        C:T ->
            {error, {Processor, {C, T}}}
    end.
