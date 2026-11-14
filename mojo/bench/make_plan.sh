#!/bin/sh
# Writes the benchmark plan: the $12 server challenge's schema, a seed, and its four operations,
# at 1/50 of the challenge's size so a throwaway FoundationDB in a container finishes in minutes.
# One line per step: kind|name|iterations|statements per transaction|sql
#   exec  runs once inside a transaction (schema and seed)
#   loop  runs a prepared statement `iterations` times, `per_txn` of them to a transaction
# The operations are the challenge's SPEC.md SQL; random ids come from SQLite's random().
#
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -eu
USERS=${USERS:-5000}
POSTS=${POSTS:-20000}
LIKES=${LIKES:-40000}
CHUNK=2000

echo "exec|schema|1|1|CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))); CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500), created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))); CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id), created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), PRIMARY KEY (user_id, post_id)); CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC); CREATE INDEX posts_user_id_idx ON posts (user_id); CREATE INDEX likes_post_id_idx ON likes (post_id)"

a=1
while [ "$a" -le "$USERS" ]; do
	b=$((a + CHUNK - 1)); [ "$b" -gt "$USERS" ] && b=$USERS
	echo "exec|seed users $a-$b|1|1|WITH RECURSIVE c(x) AS (SELECT $a UNION ALL SELECT x+1 FROM c WHERE x<$b) INSERT INTO users(id,username,created_at) SELECT x, 'user' || x, strftime('%Y-%m-%dT%H:%M:%fZ', 1700000000 + x, 'unixepoch') FROM c"
	a=$((b + 1))
done
a=1
while [ "$a" -le "$POSTS" ]; do
	b=$((a + CHUNK - 1)); [ "$b" -gt "$POSTS" ] && b=$POSTS
	echo "exec|seed posts $a-$b|1|1|WITH RECURSIVE c(x) AS (SELECT $a UNION ALL SELECT x+1 FROM c WHERE x<$b) INSERT INTO posts(id,user_id,body,created_at) SELECT x, (x * 7919) % $USERS + 1, 'post number ' || x || ' about servers, queries, latency and the price of one small droplet', strftime('%Y-%m-%dT%H:%M:%fZ', 1700000000 + x * 30, 'unixepoch') FROM c"
	a=$((b + 1))
done
a=1
while [ "$a" -le "$LIKES" ]; do
	b=$((a + CHUNK - 1)); [ "$b" -gt "$LIKES" ] && b=$LIKES
	echo "exec|seed likes $a-$b|1|1|WITH RECURSIVE c(x) AS (SELECT $a UNION ALL SELECT x+1 FROM c WHERE x<$b) INSERT OR IGNORE INTO likes(user_id,post_id,created_at) SELECT (x * 104729) % $USERS + 1, (x * 15485863) % $POSTS + 1, strftime('%Y-%m-%dT%H:%M:%fZ', 1700000000 + x, 'unixepoch') FROM c"
	a=$((b + 1))
done

POST="SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count FROM posts p JOIN users u ON u.id = p.user_id"
echo "loop|GET /feed (20 newest + like counts)|300|1|$POST ORDER BY p.created_at DESC, p.id DESC LIMIT 20"
echo "loop|GET /posts/:id|1000|1|$POST WHERE p.id = abs(random()) % $POSTS + 1"
echo "loop|POST /posts/:id/like, one commit each|200|1|INSERT INTO likes (user_id, post_id) VALUES (abs(random()) % $USERS + 1, abs(random()) % $POSTS + 1) ON CONFLICT (user_id, post_id) DO NOTHING"
echo "loop|POST /posts/:id/like, 50 to a commit|1000|50|INSERT INTO likes (user_id, post_id) VALUES (abs(random()) % $USERS + 1, abs(random()) % $POSTS + 1) ON CONFLICT (user_id, post_id) DO NOTHING"
echo "loop|POST /posts, one commit each|100|1|INSERT INTO posts (user_id, body) VALUES (abs(random()) % $USERS + 1, 'a new post from the benchmark') RETURNING id, created_at"
echo "loop|POST /posts, 50 to a commit|500|50|INSERT INTO posts (user_id, body) VALUES (abs(random()) % $USERS + 1, 'a new post from the benchmark') RETURNING id, created_at"
echo "loop|GET /feed again (after the writes)|300|1|$POST ORDER BY p.created_at DESC, p.id DESC LIMIT 20"
