defmodule Indexer.Block.Catchup.FetcherTest do
  use EthereumJSONRPC.Case, async: false
  use Explorer.DataCase

  import EthereumJSONRPC, only: [integer_to_quantity: 1]
  import Mox

  alias Explorer.Chain
  alias Explorer.Chain.Block.Reward
  alias Explorer.Chain.Hash
  alias Explorer.Utility.MissingRangesManipulator
  alias Explorer.Utility.MissingBlockRange
  alias Indexer.Block
  alias Indexer.Block.Catchup.Fetcher
  alias Indexer.Block.Catchup.MissingRangesCollector
  alias Indexer.Fetcher.CoinBalance.Catchup, as: CoinBalanceCatchup
  alias Indexer.Fetcher.{BlockReward, InternalTransaction, Token, TokenBalance, UncleBlock}
  alias Indexer.Fetcher.OnDemand.ContractCreator, as: ContractCreatorOnDemand

  @moduletag capture_log: true

  # MUST use global mode because we aren't guaranteed to get `start_supervised`'s pid back fast enough to `allow` it to
  # use expectations and stubs from test's pid.
  setup :set_mox_global

  setup :verify_on_exit!

  setup do
    # Uncle don't occur on POA chains, so there's no way to test this using the public addresses, so mox-only testing
    %{
      json_rpc_named_arguments: [
        transport: EthereumJSONRPC.Mox,
        transport_options: [],
        # Which one does not matter, so pick one
        variant: EthereumJSONRPC.Nethermind
      ]
    }
  end

  describe "import/1" do
    setup do
      configuration = Application.get_env(:indexer, :last_block)
      Application.put_env(:indexer, :last_block, 0)
      Application.put_env(:indexer, Indexer.Fetcher.Celo.EpochBlockOperations.Supervisor, disabled?: true)

      {:ok, _pid} = ContractCreatorOnDemand.start_link([[], []])

      on_exit(fn ->
        Application.put_env(:indexer, :last_block, configuration)
      end)
    end

    test "fetches uncles asynchronously", %{json_rpc_named_arguments: json_rpc_named_arguments} do
      CoinBalanceCatchup.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      InternalTransaction.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      Token.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      TokenBalance.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)

      Indexer.Fetcher.Filecoin.AddressInfo.Supervisor.Case.start_supervised!(
        json_rpc_named_arguments: json_rpc_named_arguments
      )

      MissingRangesCollector.start_link([])
      MissingRangesManipulator.start_link([])

      parent = self()

      pid =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:buffer, uncles, _front?}} ->
              GenServer.reply(from, :ok)
              send(parent, {:uncles, uncles})
          end
        end)

      Process.register(pid, UncleBlock)

      nephew_hash_data = block_hash()
      %Hash{bytes: nephew_hash_bytes} = nephew_hash_data
      nephew_hash = nephew_hash_data |> to_string()
      nephew_index = 0
      uncle_hash = block_hash() |> to_string()
      miner_hash = address_hash() |> to_string()
      block_number = 0

      assert {:ok, _} =
               Fetcher.import(%Block.Fetcher{json_rpc_named_arguments: json_rpc_named_arguments}, %{
                 addresses: %{
                   params: [
                     %{hash: miner_hash}
                   ]
                 },
                 address_hash_to_fetched_balance_block_number: %{miner_hash => block_number},
                 address_coin_balances: %{
                   params: [
                     %{
                       address_hash: miner_hash,
                       block_number: block_number
                     }
                   ]
                 },
                 blocks: %{
                   params: [
                     %{
                       difficulty: 0,
                       gas_limit: 21000,
                       gas_used: 21000,
                       miner_hash: miner_hash,
                       nonce: 0,
                       number: block_number,
                       parent_hash:
                         block_hash()
                         |> to_string(),
                       size: 0,
                       timestamp: DateTime.utc_now(),
                       total_difficulty: 0,
                       hash: nephew_hash
                     }
                   ]
                 },
                 block_rewards: %{errors: [], params: []},
                 block_second_degree_relations: %{
                   params: [
                     %{
                       nephew_hash: nephew_hash,
                       uncle_hash: uncle_hash,
                       index: nephew_index
                     }
                   ]
                 },
                 tokens: %{
                   params: [],
                   on_conflict: :nothing
                 },
                 address_token_balances: %{
                   params: []
                 },
                 transactions: %{
                   params: [],
                   on_conflict: :nothing
                 }
               })

      assert_receive {:uncles, [{^nephew_hash_bytes, ^nephew_index}]}
    end
  end

  describe "task/1" do
    setup do
      initial_env = Application.get_env(:indexer, :block_ranges)
      on_exit(fn -> Application.put_env(:indexer, :block_ranges, initial_env) end)
      Application.put_env(:indexer, Indexer.Fetcher.Celo.EpochBlockOperations.Supervisor, disabled?: true)

      Application.put_env(:explorer, Explorer.Chain.Cache.CeloCoreContracts,
        contracts: %{
          "addresses" => %{
            "Accounts" => [],
            "Election" => [],
            "EpochRewards" => [],
            "FeeHandler" => [],
            "GasPriceMinimum" => [],
            "GoldToken" => [],
            "Governance" => [],
            "LockedGold" => [],
            "Reserve" => [],
            "StableToken" => [],
            "Validators" => []
          }
        }
      )

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.Chain.Cache.CeloCoreContracts, contracts: %{})
      end)
    end

    test "ignores fetched beneficiaries with different hash for same number", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      Application.put_env(:indexer, Indexer.Block.Catchup.Fetcher, batch_size: 1, concurrency: 10)
      Application.put_env(:indexer, :block_ranges, "0..1")
      start_supervised!({Task.Supervisor, name: Indexer.Block.Catchup.TaskSupervisor})
      CoinBalanceCatchup.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      InternalTransaction.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      Token.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      TokenBalance.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      MissingRangesCollector.start_link([])
      MissingRangesManipulator.start_link([])

      latest_block_number = 2
      latest_block_quantity = integer_to_quantity(latest_block_number)

      block_number = latest_block_number - 1
      block_hash = block_hash()
      block_hash_0 = block_hash()
      block_quantity = integer_to_quantity(block_number)

      miner_hash = address_hash()
      miner_hash_data = to_string(miner_hash)
      miner_hash_0 = address_hash()
      miner_hash_0_data = to_string(miner_hash_0)

      new_block_hash = block_hash()

      refute block_hash == new_block_hash

      EthereumJSONRPC.Mox
      |> expect(:json_rpc, 4, fn
        %{method: "eth_getBlockByNumber", params: ["latest", false]}, _options ->
          {:ok, %{"number" => latest_block_quantity}}

        [
          %{
            id: id,
            jsonrpc: "2.0",
            method: "eth_getBlockByNumber",
            params: [^block_quantity, true]
          }
        ],
        _options ->
          {:ok,
           [
             %{
               id: id,
               jsonrpc: "2.0",
               result: %{
                 "hash" => to_string(block_hash),
                 "number" => block_quantity,
                 "difficulty" => "0x0",
                 "gasLimit" => "0x0",
                 "gasUsed" => "0x0",
                 "extraData" => "0x0",
                 "logsBloom" => "0x0",
                 "miner" => miner_hash_data,
                 "parentHash" =>
                   block_hash()
                   |> to_string(),
                 "receiptsRoot" => "0x0",
                 "size" => "0x0",
                 "sha3Uncles" => "0x0",
                 "stateRoot" => "0x0",
                 "timestamp" => "0x0",
                 "totalDifficulty" => "0x0",
                 "transactions" => [],
                 "transactionsRoot" => "0x0",
                 "uncles" => []
               }
             }
           ]}

        [%{id: id, jsonrpc: "2.0", method: "trace_block", params: [^block_quantity]}], _options ->
          {
            :ok,
            [
              %{
                id: id,
                jsonrpc: "2.0",
                result: [
                  %{
                    "action" => %{
                      "author" => miner_hash_data,
                      "rewardType" => "external",
                      "value" => "0x0"
                    },
                    "blockHash" => to_string(new_block_hash),
                    "blockNumber" => block_number,
                    "result" => nil,
                    "subtraces" => 0,
                    "traceAddress" => [],
                    "transactionHash" => nil,
                    "transactionPosition" => nil,
                    "type" => "reward"
                  }
                ]
              }
            ]
          }

        [
          %{
            id: id,
            jsonrpc: "2.0",
            method: "eth_getBlockByNumber",
            params: ["0x0", true]
          }
        ],
        _options ->
          {:ok,
           [
             %{
               id: id,
               jsonrpc: "2.0",
               result: %{
                 "hash" => to_string(block_hash_0),
                 "number" => "0x0",
                 "difficulty" => "0x0",
                 "gasLimit" => "0x0",
                 "gasUsed" => "0x0",
                 "extraData" => "0x0",
                 "logsBloom" => "0x0",
                 "miner" => miner_hash_0_data,
                 "parentHash" =>
                   block_hash()
                   |> to_string(),
                 "receiptsRoot" => "0x0",
                 "size" => "0x0",
                 "sha3Uncles" => "0x0",
                 "stateRoot" => "0x0",
                 "timestamp" => "0x0",
                 "totalDifficulty" => "0x0",
                 "transactions" => [],
                 "transactionsRoot" => "0x0",
                 "uncles" => []
               }
             }
           ]}
      end)

      assert count(Chain.Block) == 0

      Process.sleep(50)

      assert %{first_block_number: ^block_number, last_block_number: 0, missing_block_count: 2, shrunk: false} =
               Fetcher.task(%Fetcher{
                 block_fetcher: %Block.Fetcher{
                   callback_module: Fetcher,
                   json_rpc_named_arguments: json_rpc_named_arguments
                 }
               })

      Process.sleep(3000)

      assert count(Chain.Block) == 1
      assert count(Reward) == 0
    end

    test "async fetches beneficiaries when individual responses error out", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      Application.put_env(:indexer, Indexer.Block.Catchup.Fetcher, batch_size: 1, concurrency: 10)
      Application.put_env(:indexer, :block_ranges, "0..1")
      start_supervised!({Task.Supervisor, name: Indexer.Block.Catchup.TaskSupervisor})
      CoinBalanceCatchup.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      InternalTransaction.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      Token.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      TokenBalance.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      MissingRangesCollector.start_link([])
      MissingRangesManipulator.start_link([])

      latest_block_number = 2
      latest_block_quantity = integer_to_quantity(latest_block_number)

      block_number = latest_block_number - 1
      block_hash = block_hash()
      block_hash_0 = block_hash()
      block_quantity = integer_to_quantity(block_number)

      miner_hash = address_hash()
      miner_hash_data = to_string(miner_hash)
      miner_hash_0 = address_hash()
      miner_hash_0_data = to_string(miner_hash_0)

      new_block_hash = block_hash()

      refute block_hash == new_block_hash

      EthereumJSONRPC.Mox
      |> expect(:json_rpc, 5, fn
        %{method: "eth_getBlockByNumber", params: ["latest", false]}, _options ->
          {:ok, %{"number" => latest_block_quantity}}

        [
          %{
            id: id,
            jsonrpc: "2.0",
            method: "eth_getBlockByNumber",
            params: [^block_quantity, true]
          }
        ],
        _options ->
          {:ok,
           [
             %{
               id: id,
               jsonrpc: "2.0",
               result: %{
                 "hash" => to_string(block_hash),
                 "number" => block_quantity,
                 "difficulty" => "0x0",
                 "gasLimit" => "0x0",
                 "gasUsed" => "0x0",
                 "extraData" => "0x0",
                 "logsBloom" => "0x0",
                 "miner" => miner_hash_data,
                 "parentHash" =>
                   block_hash()
                   |> to_string(),
                 "receiptsRoot" => "0x0",
                 "size" => "0x0",
                 "sha3Uncles" => "0x0",
                 "stateRoot" => "0x0",
                 "timestamp" => "0x0",
                 "totalDifficulty" => "0x0",
                 "transactions" => [],
                 "transactionsRoot" => "0x0",
                 "uncles" => []
               }
             }
           ]}

        [
          %{
            id: id,
            jsonrpc: "2.0",
            method: "eth_getBlockByNumber",
            params: ["0x0", true]
          }
        ],
        _options ->
          {:ok,
           [
             %{
               id: id,
               jsonrpc: "2.0",
               result: %{
                 "hash" => to_string(block_hash_0),
                 "number" => "0x0",
                 "difficulty" => "0x0",
                 "gasLimit" => "0x0",
                 "gasUsed" => "0x0",
                 "extraData" => "0x0",
                 "logsBloom" => "0x0",
                 "miner" => miner_hash_0_data,
                 "parentHash" =>
                   block_hash()
                   |> to_string(),
                 "receiptsRoot" => "0x0",
                 "size" => "0x0",
                 "sha3Uncles" => "0x0",
                 "stateRoot" => "0x0",
                 "timestamp" => "0x0",
                 "totalDifficulty" => "0x0",
                 "transactions" => [],
                 "transactionsRoot" => "0x0",
                 "uncles" => []
               }
             }
           ]}

        [%{id: id, method: "trace_block", params: [^block_quantity]}], _options ->
          {:ok,
           [
             %{
               id: id,
               jsonrpc: "2.0",
               result: nil
             }
           ]}
      end)

      assert count(Chain.Block) == 0

      parent = self()

      pid =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:buffer, block_numbers, _front?}} ->
              GenServer.reply(from, :ok)
              send(parent, {:block_numbers, block_numbers})
          end
        end)

      Process.register(pid, BlockReward)

      Process.sleep(50)

      assert %{first_block_number: ^block_number, last_block_number: 0, missing_block_count: 2, shrunk: false} =
               Fetcher.task(%Fetcher{
                 block_fetcher: %Block.Fetcher{
                   callback_module: Fetcher,
                   json_rpc_named_arguments: json_rpc_named_arguments
                 }
               })

      Process.sleep(3000)

      assert count(Chain.Block) == 1
      assert count(Reward) == 0

      assert_receive {:block_numbers, [^block_number]}, 5_000
    end

    test "async fetches beneficiaries when entire call errors out", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      Application.put_env(:indexer, Indexer.Block.Catchup.Fetcher, batch_size: 1, concurrency: 10)
      Application.put_env(:indexer, :block_ranges, "0..1")
      start_supervised!({Task.Supervisor, name: Indexer.Block.Catchup.TaskSupervisor})
      CoinBalanceCatchup.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      InternalTransaction.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      Token.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      TokenBalance.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
      MissingRangesCollector.start_link([])
      MissingRangesManipulator.start_link([])

      latest_block_number = 2
      latest_block_quantity = integer_to_quantity(latest_block_number)

      block_number = latest_block_number - 1
      block_hash = block_hash()
      block_hash_0 = block_hash()
      block_quantity = integer_to_quantity(block_number)

      miner_hash = address_hash()
      miner_hash_data = to_string(miner_hash)
      miner_hash_0 = address_hash()
      miner_hash_0_data = to_string(miner_hash_0)

      new_block_hash = block_hash()

      refute block_hash == new_block_hash

      EthereumJSONRPC.Mox
      |> expect(:json_rpc, 4, fn
        %{method: "eth_getBlockByNumber", params: ["latest", false]}, _options ->
          {:ok, %{"number" => latest_block_quantity}}

        [
          %{
            id: id,
            jsonrpc: "2.0",
            method: "eth_getBlockByNumber",
            params: [^block_quantity, true]
          }
        ],
        _options ->
          {:ok,
           [
             %{
               id: id,
               jsonrpc: "2.0",
               result: %{
                 "hash" => to_string(block_hash),
                 "number" => block_quantity,
                 "difficulty" => "0x0",
                 "gasLimit" => "0x0",
                 "gasUsed" => "0x0",
                 "extraData" => "0x0",
                 "logsBloom" => "0x0",
                 "miner" => miner_hash_data,
                 "parentHash" =>
                   block_hash()
                   |> to_string(),
                 "receiptsRoot" => "0x0",
                 "size" => "0x0",
                 "sha3Uncles" => "0x0",
                 "stateRoot" => "0x0",
                 "timestamp" => "0x0",
                 "totalDifficulty" => "0x0",
                 "transactions" => [],
                 "transactionsRoot" => "0x0",
                 "uncles" => []
               }
             }
           ]}

        [%{method: "trace_block", params: [^block_quantity]}], _options ->
          {:error, :boom}

        [
          %{
            id: id,
            jsonrpc: "2.0",
            method: "eth_getBlockByNumber",
            params: ["0x0", true]
          }
        ],
        _options ->
          {:ok,
           [
             %{
               id: id,
               jsonrpc: "2.0",
               result: %{
                 "hash" => to_string(block_hash_0),
                 "number" => "0x0",
                 "difficulty" => "0x0",
                 "gasLimit" => "0x0",
                 "gasUsed" => "0x0",
                 "extraData" => "0x0",
                 "logsBloom" => "0x0",
                 "miner" => miner_hash_0_data,
                 "parentHash" =>
                   block_hash()
                   |> to_string(),
                 "receiptsRoot" => "0x0",
                 "size" => "0x0",
                 "sha3Uncles" => "0x0",
                 "stateRoot" => "0x0",
                 "timestamp" => "0x0",
                 "totalDifficulty" => "0x0",
                 "transactions" => [],
                 "transactionsRoot" => "0x0",
                 "uncles" => []
               }
             }
           ]}
      end)

      assert count(Chain.Block) == 0

      parent = self()

      pid =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:buffer, block_numbers, _front?}} ->
              GenServer.reply(from, :ok)
              send(parent, {:block_numbers, block_numbers})
          end
        end)

      Process.register(pid, BlockReward)

      Process.sleep(50)

      assert %{first_block_number: ^block_number, last_block_number: 0, missing_block_count: 2, shrunk: false} =
               Fetcher.task(%Fetcher{
                 block_fetcher: %Block.Fetcher{
                   callback_module: Fetcher,
                   json_rpc_named_arguments: json_rpc_named_arguments
                 }
               })

      Process.sleep(3000)
      assert count(Chain.Block) == 1
      assert count(Reward) == 0

      assert_receive {:block_numbers, [^block_number]}, 5_000
    end

    test "failed blocks handles correctly", %{json_rpc_named_arguments: json_rpc_named_arguments} do
      Application.put_env(:indexer, Indexer.Block.Catchup.Fetcher, batch_size: 2, concurrency: 10)
      Application.put_env(:indexer, :block_ranges, "0..1")
      start_supervised!({Task.Supervisor, name: Indexer.Block.Catchup.TaskSupervisor})
      MissingRangesCollector.start_link([])
      MissingRangesManipulator.start_link([])

      EthereumJSONRPC.Mox
      |> expect(:json_rpc, 1, fn
        [
          %{
            id: id_1,
            jsonrpc: "2.0",
            method: "eth_getBlockByNumber",
            params: ["0x1", true]
          },
          %{
            id: id_2,
            jsonrpc: "2.0",
            method: "eth_getBlockByNumber",
            params: ["0x0", true]
          }
        ],
        _options ->
          {:ok,
           [
             %{
               id: id_1,
               jsonrpc: "2.0",
               error: %{message: "error"}
             },
             %{
               id: id_2,
               jsonrpc: "2.0",
               error: %{message: "error"}
             }
           ]}
      end)

      Process.sleep(50)

      assert %{first_block_number: 1, last_block_number: 0, missing_block_count: 2, shrunk: false} =
               Fetcher.task(%Fetcher{
                 block_fetcher: %Block.Fetcher{
                   callback_module: Fetcher,
                   json_rpc_named_arguments: json_rpc_named_arguments
                 }
               })

      Process.sleep(1000)

      assert %{from_number: 1, to_number: 0} = Repo.one(MissingBlockRange)
    end

    if Application.compile_env(:explorer, :chain_type) == :stability do
      test "update stability validator counter", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        Application.put_env(:indexer, Indexer.Block.Catchup.Fetcher, batch_size: 1, concurrency: 10)
        Application.put_env(:indexer, :block_ranges, "1..2")
        start_supervised!({Task.Supervisor, name: Indexer.Block.Catchup.TaskSupervisor})
        CoinBalanceCatchup.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
        InternalTransaction.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
        Token.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
        TokenBalance.Supervisor.Case.start_supervised!(json_rpc_named_arguments: json_rpc_named_arguments)
        MissingRangesCollector.start_link([])
        MissingRangesManipulator.start_link([])

        latest_block_number = 3
        latest_block_quantity = integer_to_quantity(latest_block_number)

        block_number = latest_block_number - 1
        block_hash = block_hash()
        block_hash_1 = block_hash()
        block_quantity = integer_to_quantity(block_number)
        block_quantity_1 = integer_to_quantity(block_number - 1)

        validator = insert(:validator_stability)
        miner_hash_data = to_string(validator.address_hash)
        miner_hash_0 = address_hash()
        miner_hash_0_data = to_string(miner_hash_0)

        new_block_hash = block_hash()

        refute block_hash == new_block_hash

        EthereumJSONRPC.Mox
        |> expect(:json_rpc, 4, fn
          %{method: "eth_getBlockByNumber", params: ["latest", false]}, _options ->
            {:ok, %{"number" => latest_block_quantity}}

          [
            %{
              id: id,
              jsonrpc: "2.0",
              method: "eth_getBlockByNumber",
              params: [^block_quantity, true]
            }
          ],
          _options ->
            {:ok,
             [
               %{
                 id: id,
                 jsonrpc: "2.0",
                 result: %{
                   "hash" => to_string(block_hash),
                   "number" => block_quantity,
                   "difficulty" => "0x0",
                   "gasLimit" => "0x0",
                   "gasUsed" => "0x0",
                   "extraData" => "0x0",
                   "logsBloom" => "0x0",
                   "miner" => miner_hash_data,
                   "parentHash" =>
                     block_hash()
                     |> to_string(),
                   "receiptsRoot" => "0x0",
                   "size" => "0x0",
                   "sha3Uncles" => "0x0",
                   "stateRoot" => "0x0",
                   "timestamp" => "0x0",
                   "totalDifficulty" => "0x0",
                   "transactions" => [],
                   "transactionsRoot" => "0x0",
                   "uncles" => []
                 }
               }
             ]}

          [%{id: id, jsonrpc: "2.0", method: "trace_block", params: [^block_quantity]}], _options ->
            {
              :ok,
              [
                %{
                  id: id,
                  jsonrpc: "2.0",
                  result: []
                }
              ]
            }

          [%{id: id, jsonrpc: "2.0", method: "trace_block", params: [^block_quantity_1]}], _options ->
            {
              :ok,
              [
                %{
                  id: id,
                  jsonrpc: "2.0",
                  result: []
                }
              ]
            }

          [
            %{
              id: id,
              jsonrpc: "2.0",
              method: "eth_getBlockByNumber",
              params: [^block_quantity_1, true]
            }
          ],
          _options ->
            {:ok,
             [
               %{
                 id: id,
                 jsonrpc: "2.0",
                 result: %{
                   "hash" => to_string(block_hash_1),
                   "number" => block_quantity_1,
                   "difficulty" => "0x0",
                   "gasLimit" => "0x0",
                   "gasUsed" => "0x0",
                   "extraData" => "0x0",
                   "logsBloom" => "0x0",
                   "miner" => miner_hash_data,
                   "parentHash" =>
                     block_hash()
                     |> to_string(),
                   "receiptsRoot" => "0x0",
                   "size" => "0x0",
                   "sha3Uncles" => "0x0",
                   "stateRoot" => "0x0",
                   "timestamp" => "0x0",
                   "totalDifficulty" => "0x0",
                   "transactions" => [],
                   "transactionsRoot" => "0x0",
                   "uncles" => []
                 }
               }
             ]}
        end)

        assert count(Chain.Block) == 0

        Process.sleep(50)

        assert %{first_block_number: ^block_number, last_block_number: 1, missing_block_count: 2, shrunk: false} =
                 Fetcher.task(%Fetcher{
                   block_fetcher: %Block.Fetcher{
                     callback_module: Fetcher,
                     json_rpc_named_arguments: json_rpc_named_arguments
                   }
                 })

        Process.sleep(3000)

        assert count(Chain.Block) == 2

        validator_from_db = Repo.get!(Explorer.Chain.Stability.Validator, validator.address_hash)
        assert validator_from_db.blocks_validated == validator.blocks_validated + 2
      end
    end
  end

  defp count(schema) do
    Repo.one!(select(schema, fragment("COUNT(*)")))
  end
end
