// 改自 photoai-mac-v2 a291868 Sources/PhotoAICore/Schema.swift：版本从 1 重新开始，Mac 版的 1–6 合成一段，
// 去掉人物、OCR、地点；卷只有一行（开发计划 §5）。
import Foundation

/// 表结构与升级。见开发计划 §5、Mac 版 docs/设计/数据模型.md §3。
///
/// 用 `PRAGMA user_version` 记版本；每个版本一段 SQL，按顺序执行，已执行过的跳过。
enum Schema {
    static let migrations: [String] = [
        // 1：M1。
        """
        -- 只有一张卡：固定一行 id = 1。留着这张表是为了少改扫描代码（locations、scan_dirs 里的 volume_id 都是 1）。
        CREATE TABLE volumes (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            bookmark BLOB,
            last_seen_at REAL,
            last_scanned_at REAL
        );
        INSERT INTO volumes (id) VALUES (1);

        CREATE TABLE import_batches (
            id INTEGER PRIMARY KEY,
            volume_id INTEGER NOT NULL REFERENCES volumes(id),
            started_at REAL NOT NULL,
            finished_at REAL,
            photo_count INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE photos (
            id INTEGER PRIMARY KEY,
            identity_key TEXT NOT NULL UNIQUE,
            base_name TEXT NOT NULL,
            file_number INTEGER,
            capture_date TEXT,
            capture_subsec TEXT,
            camera_make TEXT,
            camera_model TEXT,
            lens TEXT,
            focal_length REAL,
            aperture REAL,
            shutter REAL,
            iso INTEGER,
            width INTEGER,
            height INTEGER,
            latitude REAL,
            longitude REAL,
            rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
            flag TEXT NOT NULL DEFAULT 'none' CHECK (flag IN ('none', 'pick', 'reject')),
            preview_file_id INTEGER,
            thumb_state TEXT NOT NULL DEFAULT 'pending' CHECK (thumb_state IN ('pending', 'ready', 'failed')),
            preview_state TEXT NOT NULL DEFAULT 'pending' CHECK (preview_state IN ('pending', 'ready', 'failed')),
            -- 卡上的现存位置数；0 就是“卡上已删”，照常显示（功能列表 F-06）。
            present_location_count INTEGER NOT NULL DEFAULT 0 CHECK (present_location_count >= 0),
            -- pending 还没读；found 读到了；none 这台相机没记（或没对上焦）。转正后的照片上，左上为原点，0–1。
            focus_state TEXT NOT NULL DEFAULT 'pending',
            focus_x REAL,
            focus_y REAL,
            focus_w REAL,
            focus_h REAL,
            -- 最后一次导出成功的时间（清卡检查的“选过但没导出”用，M3）。
            last_exported_at REAL,
            imported_at REAL NOT NULL,
            import_batch_id INTEGER REFERENCES import_batches(id)
        );
        -- 网格的主查询：按拍摄时间排序。
        CREATE INDEX photos_date ON photos(capture_date, capture_subsec, base_name);
        CREATE INDEX photos_batch ON photos(import_batch_id);
        CREATE INDEX photos_number ON photos(file_number);
        CREATE INDEX photos_base_name ON photos(base_name COLLATE NOCASE);
        CREATE INDEX photos_focus_state ON photos(focus_state) WHERE focus_state = 'pending';

        CREATE TABLE files (
            id INTEGER PRIMARY KEY,
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            extension TEXT NOT NULL,
            kind TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            UNIQUE (photo_id, extension)
        );

        CREATE TABLE locations (
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            volume_id INTEGER NOT NULL REFERENCES volumes(id),
            relative_path TEXT NOT NULL,
            dir_path TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            file_mtime REAL NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('present', 'historical')),
            last_seen_at REAL NOT NULL
        );
        -- 同一路径只能有一个现存位置；历史位置可以有多条（先后放过的不同照片）。
        CREATE UNIQUE INDEX locations_present_path ON locations(volume_id, relative_path) WHERE status = 'present';
        CREATE INDEX locations_path ON locations(volume_id, relative_path);
        CREATE INDEX locations_dir ON locations(volume_id, dir_path, status);
        CREATE INDEX locations_file ON locations(file_id);

        CREATE TABLE scan_dirs (
            volume_id INTEGER NOT NULL REFERENCES volumes(id),
            dir_path TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('complete', 'incomplete')),
            last_complete_at REAL,
            last_error TEXT,
            PRIMARY KEY (volume_id, dir_path)
        );

        CREATE TABLE collections (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_used_at REAL
        );
        CREATE TABLE collection_members (
            collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            added_at REAL NOT NULL,
            PRIMARY KEY (collection_id, photo_id)
        );
        CREATE INDEX collection_members_photo ON collection_members(photo_id);

        -- 标签固定 9 个位置，顺序决定快捷键；名字为空表示这个位置没用。
        CREATE TABLE labels (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL DEFAULT '',
            color TEXT NOT NULL,
            sort_order INTEGER NOT NULL UNIQUE
        );
        INSERT INTO labels (name, color, sort_order) VALUES
            ('经典', '#e5484d', 0), ('人像', '#f5a524', 1), ('风景', '#30a46c', 2), ('人文', '#3e63dd', 3),
            ('', '#8e4ec6', 4), ('', '#12a594', 5), ('', '#e93d82', 6), ('', '#ad7f58', 7), ('', '#8b8d98', 8);
        CREATE TABLE photo_labels (
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            label_id INTEGER NOT NULL REFERENCES labels(id) ON DELETE CASCADE,
            PRIMARY KEY (photo_id, label_id)
        ) WITHOUT ROWID;
        CREATE INDEX photo_labels_label ON photo_labels(label_id);

        CREATE TABLE library_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        """
    ]

    static func migrate(_ database: Database) throws {
        let current = try database.scalarInt("PRAGMA user_version;")
        guard current < migrations.count else { return }
        try database.transaction {
            for version in current..<migrations.count {
                try database.execute(migrations[version])
            }
            try database.execute("PRAGMA user_version = \(migrations.count);")
        }
    }
}
