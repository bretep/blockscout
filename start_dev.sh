#!/bin/bash

echo "Set Environment"
direnv allow

echo "Install Mix dependencies and compile"
mix do deps.get, local.rebar --force, deps.compile

echo "Clean previous static assets"
mix phx.digest.clean

echo "Compile application"
mix compile

echo "Migrate database"
mix do ecto.create, ecto.migrate

echo "Webpack assets"
cd apps/block_scout_web/assets; npm install && node_modules/webpack/bin/webpack.js --mode development; cd -

echo "Install dev dependencies for explorer"
cd apps/explorer && npm install; cd -

#echo "Build static assets"
mix phx.digest

#echo "Enable SSL"
#cd apps/block_scout_web; mix phx.gen.cert blockscout blockscout.local; cd -

echo "Start server"
mix phx.server

