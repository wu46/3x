###
# ExpKit Graphical User Interface
#
# Author: Jaeho Shin <netj@cs.stanford.edu>
# Created: 2012-11-11
###
express = require "express"
child_process = require "child_process"
async = require "async"
Lazy = require "lazy"
_ = require "underscore"

expKitPort = parseInt process.argv[2] ? 0


RUN_COLUMN_NAME = "run#"
STATE_COLUMN_NAME = "state#"
SEQUENCE_COLUMN_NAME = "sequence#"

# use text/plain MIME type for ExpKit artifacts in run/
express.static.mime.define
    "text/plain": """
        sh env args stdin stdout stderr exitcode
        run measure
        condition assembly outcome
        plan remaining done count cmdln
    """.split /\s+/

###
# Express.js server
###
app = module.exports = express()

app.configure ->
    #app.set "views", __dirname + "/views"
    #app.set "view engine", "jade"
    app.use express.logger()
    #app.use express.bodyParser()
    #app.use express.methodOverride()
    app.use app.router
    app.use "/run", express.static    "#{process.env.EXPROOT}/run"
    app.use "/run", express.directory "#{process.env.EXPROOT}/run"
    app.use         express.static    "#{__dirname}/../client"

app.configure "development", ->
    app.use express.errorHandler({ dumpExceptions: true, showStack: true })

app.configure "production", ->
    app.use express.errorHandler()

# convert lines of multiple key=value pairs (or named columns) to an array of
# arrays with a header array:
# "k1=v1 k2=v2\nk1=v3 k3=v4\n..." ->
#   { names:[k1,k2,k3,...], rows:[[v1,v2,null],[v3,null,v4],...] }
normalizeNamedColumnLines = (
        lineToKVPairs = (line) -> line.split /\s+/
) -> (lazyLines, next) ->
    columnIndex = {}
    columnNames = []
    lazyLines
        .map(String)
        .map(lineToKVPairs)
        .filter((x) -> x?)
        .map((columns) ->
            row = []
            for column in columns
                [name, value] = column.split "=", 2
                continue unless name and value?
                idx = columnIndex[name]
                unless idx?
                    idx = columnNames.length
                    columnIndex[name] = idx
                    columnNames.push name
                row[idx] = value
            row
        )
        .join((rows) ->
            next {
                names: columnNames
                rows: rows
            }
        )


###
# CLI helpers
###
cliBare = (cmd, args, withOut, onEnd
        , withErr = (err, next) -> err.join next
) ->
    console.log "CLI running:", cmd, args.map((x) -> "'#{x}'").join " "
    p = child_process.spawn cmd, args
    _code = null; _result = null; _error = null
    tryEnd = ->
        if _code? and _error? and _result?
            _error = null unless _error?.length > 0
            onEnd _code, _error, _result...
    withOut Lazy(p.stdout).lines.map(String), (result...) -> _result = result; do tryEnd
    withErr Lazy(p.stderr).lines.map(String), (error)     -> _error  = error ; do tryEnd
    p.on "exit",                              (code)      -> _code   = code  ; do tryEnd

handleNonZeroExitCode = (res, next) -> (code, err, result...) ->
    if code is 0
        next null, result...
    else
        res.send 500, (err?.join "\n") ? err
        next err, result...

cliBareEnv = (env, cmd, args, rest...) ->
    envArgs = ("#{name}=#{value}" for name,value of env)
    cliBare "env", [envArgs..., cmd, args...], rest...

cli    = (res,      cmd, args, withOut, onEnd, withErr) -> (next) ->
    cliBare         cmd, args, withOut, (handleNonZeroExitCode res, next), withErr

cliEnv = (res, env, cmd, args, withOut, onEnd, withErr) -> (next) ->
    cliBareEnv env, cmd, args, withOut, (handleNonZeroExitCode res, next), withErr

respondJSON = (res) -> (err, result) ->
    res.json result unless err



# Allow Cross Origin AJAX Requests
app.options "/api/*", (req, res) ->
    res.set
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
        "Access-Control-Allow-Headers": req.get("access-control-request-headers")
    res.send(200)
app.get "/api/*", (req, res, next) ->
    res.set
        "Access-Control-Allow-Origin": "*"
    next()

app.get "/api/conditions", (req, res) ->
    cli(res, "exp-conditions", ["-v"]
        , (lazyLines, next) -> lazyLines
                .filter((line) -> line.length > 0)
                .map((line) ->
                        [name, value] = line.split "=", 2
                        if name and value
                            [name,
                                values: value?.split ","
                                type: "nominal" # FIXME extend exp-conditions to output datatype as well (-t?)
                            ]
                    )
                .join (pairs) -> next (_.object pairs)
    ) (err, conditions) ->
        res.json conditions unless err

app.get "/api/measurements", (req, res) ->
    cli(res, "exp-measures", []
        , (lazyLines, next) -> lazyLines
                .filter((line) -> line.length > 0)
                .map((line) ->
                    [name, type] = line.split ":", 2
                    if name?
                        [name,
                            type: type
                        ]
                )
                .join (pairs) -> next (_.object pairs)
    ) (err, measurements) ->
        unless err
            measurements[RUN_COLUMN_NAME] =
                type: "nominal"
            res.json measurements

app.get "/api/results", (req, res) ->
    args = []
    # TODO runs/batches
    conditions =
        try
            JSON.parse req.param("conditions")
        catch err
            {}
    for name,values of conditions
        if values?.length > 0
            args.push "#{name}=#{values.join ","}"
    cli(res, "exp-results", args
        , normalizeNamedColumnLines (line) ->
                [run, columns...] = line.split /\s+/
                ["#{RUN_COLUMN_NAME}=#{run}", columns...] if run
    ) (err, results) ->
        res.json results unless err

app.get "/api/run/batch.DataTables", (req, res) ->
    query = req.param("sSearch") ? ""
    async.parallel [
            cliEnv res, {
                LIMIT:  req.param("iDisplayLength") ? -1
                OFFSET: req.param("iDisplayStart") ? 0
            }, "exp-batches", ["-l", query]
                , (lazyLines, next) ->
                    lazyLines
                        .filter((line) -> line isnt "")
                        .map((line) -> line.split /\t/)
                        .join next
        ,
            cli res, "exp-batches", ["-c", query]
                , (lazyLines, next) ->
                    lazyLines
                        .take(1)
                        .join ([line]) -> next (+line.trim())
        ,
            cli res, "exp-batches", ["-c"]
                , (lazyLines, next) ->
                    lazyLines
                        .take(1)
                        .join ([line]) -> next (+line.trim())
        ], (err, [table, filteredCount, totalCount]) ->
            unless err
                res.json
                    sEcho: req.param("sEcho")
                    iTotalRecords: totalCount
                    iTotalDisplayRecords: filteredCount
                    aaData: table

app.get "/api/run/batch/:batchId", (req, res) ->
    batchId = req.param("batchId")
    # TODO sanitize batchId
    cli(res, "exp-status", [batchId]
        , normalizeNamedColumnLines (line) ->
                [state, columns..., sequence] = line.split /\s+/
                sequence = +(sequence?.replace /^#/, "")
                ["#{STATE_COLUMN_NAME}=#{state}", "#{SEQUENCE_COLUMN_NAME}=#{sequence}", columns...] if state
    ) (err, batch) ->
        res.json batch unless err


app.listen expKitPort, ->
    #console.log "ExpKit GUI started at http://localhost:%d/", expKitPort

