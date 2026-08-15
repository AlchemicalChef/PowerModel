defmodule PowerModel.Grid.DcTie do
  @moduledoc """
  An HVDC link modeled as a pair of scheduled injections (ROADMAP item 13).

  A DC link carries a *controlled* flow set by its converter controls, not one
  set by a series impedance, so it is not an AC branch and never appears in the
  Y-bus. `PowerModel.Grid.in_service_lines/1` excludes `line_type == "dc"`
  rows from every AC snapshot (REVIEW LIN-6); this schema is the replacement
  for what that exclusion removes.

  ## Sign convention

  `schedule_mw` is the scheduled real power **injected at `from_bus`**:

    * `schedule_mw > 0` — the tie DELIVERS `schedule_mw` MW into `from_bus`
      (that terminal is the inverter / receiving end) and withdraws the same
      MW at `to_bus` (rectifier / sending end).
    * `schedule_mw < 0` — reversed: `from_bus` is the sending end and exports
      `|schedule_mw|` MW.

  In injection terms the solver adds `+schedule_mw` at `from_bus` and
  `-schedule_mw` at `to_bus`. The convention is anchored on `from_bus` rather
  than on flow direction because `from_bus` is the terminal that is always
  modeled: for a tie whose far end lies outside the network `to_bus_id` is
  `nil` and only the near-end injection exists. Curated entries keep the
  conventional facility naming (e.g. "Celilo–Sylmar") and carry a negative
  schedule when the first-named terminal is the sending end.

  A tie contributes nothing to an island that contains neither of its
  terminals, and contributes only the near-end injection to an island that
  contains one. An island whose buses are blacked out drops out of the solve
  entirely, taking its half of the tie with it — a converter cannot run
  without an AC source to commutate against.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "dc_ties" do
    field :name, :string
    field :schedule_mw, :float, default: 0.0
    field :rating_mva, :float
    field :status, :string, default: "in_service"
    field :source, :string
    field :source_id, :string

    belongs_to :from_bus, PowerModel.Grid.Bus
    belongs_to :to_bus, PowerModel.Grid.Bus

    timestamps()
  end

  @cast_fields [
    :name,
    :schedule_mw,
    :rating_mva,
    :status,
    :source,
    :source_id,
    :from_bus_id,
    :to_bus_id
  ]

  def changeset(tie, attrs) do
    tie
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :schedule_mw])
    |> validate_number(:rating_mva, greater_than: 0)
    |> unique_constraint([:source, :source_id])
    |> foreign_key_constraint(:from_bus_id)
    |> foreign_key_constraint(:to_bus_id)
  end

  @doc """
  Schedule in MW that this tie is actually carrying.

  Zero when the tie is out of service — a blocked or bypassed converter moves
  no power — and zero for a degenerate tie whose two terminals are the same
  bus, which would otherwise inject and withdraw at one place. A missing
  schedule reads as zero rather than raising, so hand-built snapshots stay
  usable.
  """
  def scheduled_mw(tie) do
    from_id = Map.get(tie, :from_bus_id)

    cond do
      Map.get(tie, :status) not in [nil, "in_service"] -> 0.0
      not is_nil(from_id) and from_id == Map.get(tie, :to_bus_id) -> 0.0
      true -> Map.get(tie, :schedule_mw) || 0.0
    end
  end

  @doc """
  Scheduled injection this tie contributes at `bus_id`, in MW.

  Returns `0.0` for a bus that is neither terminal, so callers can fold ties
  into an injection vector without first checking membership.
  """
  def injection_at(tie, bus_id) do
    schedule = scheduled_mw(tie)

    cond do
      is_nil(bus_id) -> 0.0
      Map.get(tie, :from_bus_id) == bus_id -> schedule
      Map.get(tie, :to_bus_id) == bus_id -> -schedule
      true -> 0.0
    end
  end

  @doc """
  Net scheduled injection the tie contributes to a set of buses, in MW.

  Both terminals inside the set cancel to zero — a tie internal to one island
  moves power around inside it but adds none. One terminal inside yields that
  terminal's injection, which is how an import or export shows up.
  """
  def net_injection(tie, %MapSet{} = bus_ids) do
    from = if MapSet.member?(bus_ids, Map.get(tie, :from_bus_id)), do: 1.0, else: 0.0
    to = if MapSet.member?(bus_ids, Map.get(tie, :to_bus_id)), do: 1.0, else: 0.0

    scheduled_mw(tie) * (from - to)
  end

  @doc """
  Total net injection a list of ties contributes to `bus_ids`, in MW.

  This is the quantity island power balance has to account for: positive means
  the island is a net importer over its DC ties.
  """
  def net_injection_mw(ties, %MapSet{} = bus_ids) do
    Enum.reduce(ties, 0.0, fn tie, acc -> acc + net_injection(tie, bus_ids) end)
  end

  @doc "True when the tie has at least one terminal inside `bus_ids`."
  def touches?(tie, %MapSet{} = bus_ids) do
    MapSet.member?(bus_ids, Map.get(tie, :from_bus_id)) or
      MapSet.member?(bus_ids, Map.get(tie, :to_bus_id))
  end
end
