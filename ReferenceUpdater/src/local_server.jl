const URL_CACHE = Dict{String, String}()

function wipe_cache!()
    for path in values(URL_CACHE)
        rm(path, recursive = true)
    end
    empty!(URL_CACHE)
    return
end

function serve_update_page_from_dir(folder)

    folder = realpath(folder)
    @assert isdir(folder) "$folder is not a valid directory."
    split_scores(folder)
    
    router = HTTP.Router()

    function receive_update(req)
        data = JSON3.read(req.body)
        images = data["images"]
        tag = data["tag"]

        tempdir = tempname()
        recorded_folder = joinpath(folder, "recorded")
        reference_folder = joinpath(folder, "reference")

        @info "Copying reference folder to \"$tempdir\""
        cp(reference_folder, tempdir)

        for image in images
            @info "Overwriting \"$image\" in new reference folder"
            copy_filepath = joinpath(tempdir, image)
            copy_dir = splitdir(copy_filepath)[1]
            # make the path in case a new refimage is in a not yet existing folder
            mkpath(copy_dir)
            cp(joinpath(recorded_folder, image), copy_filepath, force = true)
        end

        @info "Uploading updated reference images under tag \"$tag\""
        try
            upload_reference_images(tempdir, tag)
            @info "Upload successful. You can ctrl+c out now."
            HTTP.Response(200, "Upload successful")
        catch e
            showerror(stdout, e, catch_backtrace())
            HTTP.Response(404)
        end
    end

    function serve_local_file(req)
        if req.target == "/"
            s = read(normpath(joinpath(dirname(pathof(ReferenceUpdater)), "reference_images.html")), String)
            s = replace(s, "DEFAULT_TAG" => "'$(last_major_version())'")
            return HTTP.Response(200, s)
        end
        file = HTTP.unescapeuri(req.target[2:end])
        filepath = normpath(joinpath(folder, file))
        # check that we don't go outside of the artifact folder
        if !startswith(filepath, folder)
            @info "$file leads to $filepath which is outside of the artifact folder."
            return HTTP.Response(404)
        end

        if !isfile(filepath)
            return HTTP.Response(404)
        else
            return HTTP.Response(200, read(filepath))
        end
    end

    HTTP.register!(router, "POST", "/", receive_update)
    HTTP.register!(router, "GET", "/", serve_local_file)
    HTTP.register!(router, "GET", "/**", serve_local_file)

    @info "Starting server. Open http://localhost:8849 in your browser to view. Ctrl+C to quit."
    try
        HTTP.serve(router, HTTP.Sockets.localhost, 8849)
    catch e
        if e isa InterruptException
            @info "Server stopped."
        else
            rethrow(e)
        end
    end
end

function serve_update_page(; commit = nothing, pr = nothing)
    authget(url) = HTTP.get(url, Dict("Authorization" => "token $(github_token())"))

    commit !== nothing && pr !== nothing && error("Keyword arguments `commit` and `pr` can't be set at once.")
    if pr !== nothing
        prinfo = JSON3.read(authget("https://api.github.com/repos/MakieOrg/Makie.jl/pulls/$pr").body)
        headsha = prinfo["head"]["sha"]
        @info "PR is $pr, using last commit hash $headsha"
    elseif commit !== nothing
        headsha = commit
    else
        error("You have to specify either the keyword argument `commit` or `pr`.")
    end

    checksinfo = JSON3.read(authget("https://api.github.com/repos/MakieOrg/Makie.jl/commits/$headsha/check-runs").body)

    # Somehow identical artifacts can occur double, but with different ids?
    # I don't know what happens, but we need to filter them out!
    unique_artifacts = Set{String}()
    checkruns = filter(checksinfo["check_runs"]) do checkrun
        name = checkrun["name"]
        id = checkrun["id"]
    
        if name == "Merge artifacts"
            job = JSON3.read(authget("https://api.github.com/repos/MakieOrg/Makie.jl/actions/jobs/$(id)").body)
            run = JSON3.read(authget(job["run_url"]).body)
            if run["status"] != "completed"
                @info "$(name)'s run hasn't completed yet, no artifacts will be available."
                return false
            else
                return true
            end
        else
            return false
        end
    end
    if isempty(checkruns)
        error("\"Merge artifacts\" run is not available.")
    end
    if length(checkruns) > 1
        error("Found multiple checkruns for \"Merge artifacts\", this is unexpected.")
    end

    check = only(checkruns)

    job = JSON3.read(authget("https://api.github.com/repos/MakieOrg/Makie.jl/actions/jobs/$(check["id"])").body)
    run = JSON3.read(authget(job["run_url"]).body)

    artifacts = JSON3.read(authget(run["artifacts_url"]).body)["artifacts"]

    for a in artifacts
        if a["name"] == "ReferenceImages"
            @info "Choosing artifact \"$(a["name"])\""
            download_url = a["archive_download_url"]
            if !haskey(URL_CACHE, download_url)
                @info "Downloading artifact from $download_url"
                filepath = Downloads.download(download_url, headers = Dict("Authorization" => "token $(github_token())"))
                @info "Download successful"
                tmpdir = mktempdir()
                unzip(filepath, tmpdir)
                rm(filepath)
                URL_CACHE[download_url] = tmpdir
            else
                tmpdir = URL_CACHE[download_url]
                @info "$download_url cached at $tmpdir"
            end

            @info "Serving update page from folder $tmpdir."
            serve_update_page_from_dir(tmpdir)
            return
        end
    end
    error("""
        No \"ReferenceImages\" artifact found for commit $headsha and job id $(check["id"]).
        This could be because the job's workflow run ($(job["run_url"])) has not completed, yet.
        Artifacts are only available for complete runs.
    """)
end

function unzip(file, exdir = "")
    fileFullPath = isabspath(file) ?  file : joinpath(pwd(),file)
    basePath = dirname(fileFullPath)
    outPath = (exdir == "" ? basePath : (isabspath(exdir) ? exdir : joinpath(pwd(),exdir)))
    isdir(outPath) ? "" : mkdir(outPath)
    @info "Extracting zip file $file to $outPath"
    zarchive = ZipFile.Reader(fileFullPath)
    for f in zarchive.files
        fullFilePath = joinpath(outPath,f.name)
        if (endswith(f.name,"/") || endswith(f.name,"\\"))
            mkdir(fullFilePath)
        else
            mkpath(dirname(fullFilePath))
            write(fullFilePath, read(f))
        end
    end
    close(zarchive)
    @info "Extracted zip file"
end


function split_scores(path)
    isfile(joinpath(path, "scores_table.tsv")) && return

    # Load all refimg scores into a Dict
    # `filename => (score_glmakie, score_cairomakie, score_wglmakie)`
    data = Dict{String, Vector{Float64}}()
    open(joinpath(path, "scores.tsv"), "r") do file
        for line in eachline(file)
            score, filepath = split(line, '\t')
            pieces = splitpath(filepath)
            backend = pieces[1]
            filename = join(pieces[2:end], '/')

            scores = get!(data, filename, [-1.0, -1.0, -1.0])
            if backend == "GLMakie"
                scores[1] = parse(Float64, score)
            elseif backend == "CairoMakie"
                scores[2] = parse(Float64, score)
            elseif backend == "WGLMakie"
                scores[3] = parse(Float64, score)
            else
                error("$line -> $backend")
            end
        end
    end
    
    # sort by max score across all backends so problem come first
    data_vec = collect(pairs(data))
    sort!(data_vec, by = x -> maximum(x[2]), rev = true)

    # generate new file with
    #    GLMakie         CairoMakie        WGLMakie
    # score filename   score filename   score filename
    open(joinpath(path, "scores_table.tsv"), "w") do file
        for (filename, scores) in data_vec
            skip = scores .== -1.0
            println(file,
                ifelse(skip[1], "0.0", scores[1]), '\t', ifelse(skip[1], "", "GLMakie/$filename"), '\t',
                ifelse(skip[2], "0.0", scores[2]), '\t', ifelse(skip[2], "", "CairoMakie/$filename"), '\t',
                ifelse(skip[3], "0.0", scores[3]), '\t', ifelse(skip[3], "", "WGLMakie/$filename")
            )
        end
    end

    return
end
