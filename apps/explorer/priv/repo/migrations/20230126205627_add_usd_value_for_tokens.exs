defmodule Explorer.Repo.Migrations.AddBlockNumberToPendingBlockOperations do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      add(:usd_value, :decimal)
    end
  end
end
