defmodule Revela.Repo.Migrations.AllowPhotoWithoutPreview do
  use Ecto.Migration

  def up do
    execute "PRAGMA foreign_keys = OFF"

    execute """
    CREATE TABLE photos_without_preview (
      id INTEGER PRIMARY KEY,
      seq INTEGER NOT NULL,
      web_path TEXT,
      original_path TEXT,
      raw_path TEXT,
      shot_at TEXT,
      editorial_id INTEGER REFERENCES editorials(id) ON DELETE SET NULL,
      source_hash TEXT,
      original_filename TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute """
    INSERT INTO photos_without_preview
      (id, seq, web_path, original_path, raw_path, shot_at, editorial_id,
       source_hash, original_filename, inserted_at, updated_at)
    SELECT id, seq, web_path, original_path, raw_path, shot_at, editorial_id,
           source_hash, original_filename, inserted_at, updated_at
    FROM photos
    """

    execute "DROP TABLE photos"
    execute "ALTER TABLE photos_without_preview RENAME TO photos"
    execute "CREATE UNIQUE INDEX photos_seq_index ON photos (seq)"
    execute "CREATE INDEX photos_editorial_id_index ON photos (editorial_id)"

    execute "CREATE UNIQUE INDEX photos_raw_path_unique_index ON photos (raw_path) WHERE raw_path IS NOT NULL AND raw_path != ''"

    execute "CREATE UNIQUE INDEX photos_editorial_source_hash_index ON photos (editorial_id, source_hash) WHERE source_hash IS NOT NULL AND source_hash != ''"

    execute "PRAGMA foreign_keys = ON"
  end

  def down do
    raise "Reverting AllowPhotoWithoutPreview is not supported"
  end
end
