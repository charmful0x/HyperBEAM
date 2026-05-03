Env =
    fun(Name, Default) ->
        case os:getenv(Name) of
            false -> Default;
            Raw -> list_to_binary(Raw)
        end
    end.

EnvInt =
    fun(Name, Default) ->
        case os:getenv(Name) of
            false -> Default;
            Raw -> list_to_integer(Raw)
        end
    end.

ScriptTimeout = EnvInt("SCRIPT_TIMEOUT", 7200000).
spawn(fun() ->
    timer:sleep(ScriptTimeout),
    io:format("swap-test-e2e timed out after ~p ms~n", [ScriptTimeout]),
    erlang:halt(124)
end).

Run =
    fun(Command, Args, EnvPairs) ->
        Port = open_port(
            {spawn_executable, Command},
            [
                binary,
                exit_status,
                use_stdio,
                stderr_to_stdout,
                {args, Args},
                {env, EnvPairs}
            ]
        ),
        Collect =
            fun F(Acc) ->
                receive
                    {Port, {data, Data}} ->
                        io:format("~s", [Data]),
                        F([Data | Acc]);
                    {Port, {exit_status, Status}} ->
                        {Status, iolist_to_binary(lists:reverse(Acc))}
                end
            end,
        Collect([])
    end.

NodeExec =
    case os:find_executable("node") of
        false -> error(node_not_found);
        FoundNode -> FoundNode
    end.

OperatorWalletPath = Env("OPERATOR_WALLET", <<"hyperbeam-key.json">>).
BuyerWalletPath = Env("BUYER_WALLET", Env("WALLET", <<"darwin.json">>)).
OperatorWallet = hb:wallet(OperatorWalletPath).
BuyerWallet = hb:wallet(BuyerWalletPath).
Operator = hb_util:human_id(ar_wallet:to_address(OperatorWallet)).
Buyer = hb_util:human_id(ar_wallet:to_address(BuyerWallet)).
HBNode = Env("NODE", <<"http://localhost:8734">>).
AOQuantity = EnvInt("SWAP_AO_QUANTITY", EnvInt("AO_QUANTITY", 1)).
AvailableAO = EnvInt("AVAILABLE_AO", AOQuantity).
Gateway = Env("GATEWAY", hb_opts:get(gateway, #{})).
HTTPTimeout = EnvInt("HTTP_TIMEOUT", 30000).
ConnectTimeout = EnvInt("CONNECT_TIMEOUT", 5000).
ARTxOut = binary_to_list(Env("AR_RESULT", <<"/tmp/swap-last-ar.json">>)).
E2EStatePath = binary_to_list(Env("E2E_STATE", <<"swap-wallet-e2e-state.json">>)).
application:ensure_all_started(inets).
application:ensure_all_started(ssl).

io:format("=== wallet swap e2e ===~n").
io:format("Operator AO wallet: ~s~n", [Operator]).
io:format("Buyer wallet: ~s~n~n", [Buyer]).

Base = #{
    <<"device">> => hb_opts:get(swap_device, #{}),
    <<"operator">> => Operator,
    <<"ar-recipient">> => Env("AR_RECIPIENT", Operator),
    <<"ao-source">> => Env("AO_SOURCE", Operator),
    <<"ao-token">> => Env("AO_TOKEN", hb_opts:get(ao_payment_token, #{})),
    <<"ao-submit-url">> => Env("AO_SUBMIT_URL", hb_opts:get(ao_submit_url, #{})),
    <<"price">> => EnvInt("PRICE", 1),
    <<"price-scale">> => EnvInt("PRICE_SCALE", 1),
    <<"fee-bps">> => EnvInt("FEE_BPS", 0),
    <<"verify-arweave">> => true,
    <<"available-ao">> => AvailableAO
}.

{ok, State0} = dev_swap:init(Base, #{ <<"path">> => <<"init">> }, #{}).
BuyerOpts = #{ <<"priv-wallet">> => BuyerWallet }.

ReserveReq0 = #{
    <<"path">> => <<"reserve">>,
    <<"quantity">> => AOQuantity,
    <<"recipient">> => Env("AO_RECIPIENT", Buyer)
}.
ReserveReq =
    case os:getenv("RESERVATION_ID") of
        false -> ReserveReq0;
        RawReservationID ->
            ReserveReq0#{ <<"reservation-id">> => list_to_binary(RawReservationID) }
    end.

{ok, State1} = dev_swap:reserve(State0, hb_message:commit(ReserveReq, BuyerOpts), BuyerOpts).
Reservation = maps:get(<<"last-reservation">>, State1).
ReservationID = maps:get(<<"id">>, Reservation).
ARTotal = maps:get(<<"ar-total">>, Reservation).
ARTags = maps:get(<<"ar-tags">>, Reservation).

io:format("=== reserve AO ===~n").
io:format("Reservation ID: ~s~n", [ReservationID]).
io:format("AO raw quantity: ~p~n", [maps:get(<<"ao-quantity">>, Reservation)]).
io:format("AR winston total: ~p~n", [ARTotal]).
io:format("AR recipient: ~s~n", [maps:get(<<"ar-recipient">>, Reservation)]).
io:format(
    "Required AR tags: swap-device=~s swap-reservation=~s~n",
    [maps:get(<<"swap-device">>, ARTags), ReservationID]
).

ARTxID =
    case os:getenv("AR_TX_ID") of
        false ->
            io:format("=== send buyer AR ===~n"),
            file:delete(ARTxOut),
            {ARStatus, _AROutput} =
                Run(
                    NodeExec,
                    ["scripts/swap-send-ar-arweave-js.mjs"],
                    [
                        {"WALLET", binary_to_list(BuyerWalletPath)},
                        {"GATEWAY", binary_to_list(Gateway)},
                        {"AR_RECIPIENT", binary_to_list(maps:get(<<"ar-recipient">>, Reservation))},
                        {"AR_QUANTITY", integer_to_list(ARTotal)},
                        {"RESERVATION_ID", binary_to_list(ReservationID)},
                        {"SWAP_DEVICE", binary_to_list(maps:get(<<"swap-device">>, ARTags))},
                        {"OUT", ARTxOut},
                        {"HTTP_TIMEOUT", integer_to_list(HTTPTimeout)}
                    ]
                ),
            case ARStatus of
                0 ->
                    {ok, ARResultBin} = file:read_file(ARTxOut),
                    ARResult = hb_json:decode(ARResultBin),
                    maps:get(<<"id">>, ARResult);
                _ ->
                    erlang:halt(ARStatus)
            end;
        RawARTxID ->
            list_to_binary(RawARTxID)
    end.

io:format("AR tx id: ~s~n", [ARTxID]).
file:write_file(
    E2EStatePath,
    hb_json:encode(#{
        <<"reservationId">> => ReservationID,
        <<"arTxId">> => ARTxID
    })
).

OperatorOpts =
    (hb_opts:default_message_with_env())#{
        priv_wallet => OperatorWallet,
        <<"priv-wallet">> => OperatorWallet,
        operator => Operator,
        <<"operator">> => Operator,
        <<"prometheus">> => false,
        <<"http-client">> => httpc,
        <<"http-client-connect-timeout">> => ConnectTimeout,
        <<"http-client-send-timeout">> => HTTPTimeout
    }.

SubmitReq =
    hb_message:commit(
        #{
            <<"path">> => <<"submit">>,
            <<"reservation-id">> => ReservationID,
            <<"ar-transfer-id">> => ARTxID,
            <<"ar-quantity">> => ARTotal
        },
        BuyerOpts
    ).

ARPollMS = EnvInt("AR_POLL_SECONDS", 60) * 1000.
ARDeadline =
    erlang:monotonic_time(millisecond) +
        EnvInt("AR_MAX_WAIT_MINUTES", 60) * 60 * 1000.

Submit =
    fun F(Attempt) ->
        io:format("=== submit AR proof and pay AO from operator wallet ===~n"),
        io:format("Attempt: ~p~n", [Attempt]),
        try dev_swap:submit(State1, SubmitReq, OperatorOpts) of
            {ok, State2} ->
                State2;
            {error, #{ <<"status">> := 424 } = Error} ->
                case erlang:monotonic_time(millisecond) < ARDeadline of
                    true ->
                        io:format("AR tx not visible to verifier yet: ~p~n", [Error]),
                        timer:sleep(ARPollMS),
                        F(Attempt + 1);
                    false ->
                        io:format("swap submit failed: ~p~n", [{error, Error}]),
                        erlang:halt(1)
                end;
            Error ->
                io:format("swap submit failed: ~p~n", [Error]),
                erlang:halt(1)
        catch
            Class:Reason:Stacktrace ->
                io:format(
                    "swap submit crashed: ~p:~p~nStacktrace: ~p~n",
                    [Class, Reason, Stacktrace]
                ),
                erlang:halt(1)
        end
    end.

AOMessageID =
    case os:getenv("AO_MESSAGE_ID") of
        false ->
            State2 = Submit(1),
            Released = maps:get(<<"last-release">>, State2),
            AORelease = maps:get(<<"ao-release">>, Released),
            maps:get(<<"message-id">>, AORelease);
        RawAOMessageID ->
            list_to_binary(RawAOMessageID)
    end.

io:format("AO payout message: ~s~n", [AOMessageID]).
io:format("AO recipient: ~s~n", [maps:get(<<"recipient">>, Reservation)]).
file:write_file(
    E2EStatePath,
    hb_json:encode(#{
        <<"reservationId">> => ReservationID,
        <<"arTxId">> => ARTxID,
        <<"aoMessageId">> => AOMessageID
    })
).

AOPollMS = EnvInt("AO_POLL_SECONDS", 60) * 1000.
AODeadline =
    erlang:monotonic_time(millisecond) +
        EnvInt("AO_MAX_WAIT_MINUTES", 60) * 60 * 1000.

VerifyAO =
    fun F(Attempt) ->
        io:format("=== verify AO payout ===~n"),
        io:format("Attempt: ~p~n", [Attempt]),
        {Status, _Output} =
            Run(
                NodeExec,
                [
                    "scripts/ao-payment-bridge.mjs",
                    "--verify-only",
                    "--node",
                    binary_to_list(HBNode),
                    "--message-id",
                    binary_to_list(AOMessageID),
                    "--ledger",
                    binary_to_list(Buyer),
                    "--sender",
                    binary_to_list(Operator),
                    "--quantity",
                    integer_to_list(AOQuantity),
                    "--lookback",
                    integer_to_list(EnvInt("AO_LOOKBACK", 500))
                ],
                []
            ),
        case Status of
            0 ->
                ok;
            _ ->
                case erlang:monotonic_time(millisecond) < AODeadline of
                    true ->
                        timer:sleep(AOPollMS),
                        F(Attempt + 1);
                    false ->
                        erlang:halt(Status)
                end
        end
    end.

VerifyAO(1).
io:format("Swap complete.~n").
erlang:halt(0).
