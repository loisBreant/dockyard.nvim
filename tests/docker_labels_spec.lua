local docker = require("dockyard.core.docker")

describe("docker.attach_image_labels", function()
	local stdout = table.concat({
		'{"id":"sha256:c1d2e3f4a5b6deadbeef","config":{"Cmd":["x"],"Labels":{"com.docker.compose.project":"filow-docs","x":"y"}}}',
		'{"id":"sha256:0123456789abcdef","config":{"Cmd":["/bin/sh"]}}',
		"not json",
		'{"id":"sha256:aaaaaaaaaaaa1111","config":{"Labels":{"org.opencontainers.image.source":"x"}}}',
		'{"id":"sha256:bbbbbbbbbbbb2222","config":null}',
	}, "\n")

	it("tells which compose project built each image, by the start of its id", function()
		local images = {
			{ id = "c1d2e3f4a5b6", repository = "filow-docs-docs" },
			{ id = "0123456789ab", repository = "postgres" },
			{ id = "aaaaaaaaaaaa", repository = "other" },
			{ id = "ffffffffffff", repository = "not-inspected" },
		}
		docker.attach_image_labels(images, stdout)
		eq("filow-docs", images[1].compose_project)
		eq(nil, images[2].compose_project)
		eq(nil, images[3].compose_project)
		eq(nil, images[4].compose_project)
	end)

	it("copes with nothing to read", function()
		local images = { { id = "c1d2e3f4a5b6" } }
		docker.attach_image_labels(images, "")
		docker.attach_image_labels(images, nil)
		docker.attach_image_labels({}, stdout)
		eq(nil, images[1].compose_project)
	end)
end)

describe("docker image inspect", function()
	it("accepts every image of this machine, labelled or not", function()
		if vim.fn.executable("docker") == 0 then
			return
		end
		local listed = vim.system({ "docker", "images", "-q", "--no-trunc" }, { text = true }):wait()
		local ids = vim.split(listed.stdout or "", "\n", { trimempty = true })
		if listed.code ~= 0 or #ids == 0 then
			return -- no daemon, or nothing to inspect
		end
		eq("string", type(docker.IMAGE_INSPECT_FORMAT))
		local args = { "docker", "image", "inspect", "--format", docker.IMAGE_INSPECT_FORMAT }
		vim.list_extend(args, ids)
		local res = vim.system(args, { text = true }):wait()
		eq(0, res.code, res.stderr)
	end)

	it("keeps the labels of the images it could inspect when another one is gone", function()
		local real = docker.run
		docker.run = function(args, cb)
			if args[1] == "images" then
				cb({
					ok = true,
					data = '{"id":"c1d2e3f4a5b6","repository":"a","tag":"b"}\n{"id":"ffffffffffff","repository":"gone","tag":"x"}',
				})
			else
				cb({
					ok = false,
					error = "No such image: ffffffffffff",
					data = '{"id":"sha256:c1d2e3f4a5b6dead","config":{"Labels":{"com.docker.compose.project":"p"}}}\n',
				})
			end
		end
		local got
		docker.list_images(function(res)
			got = res
		end)
		docker.run = real
		eq(true, got.ok)
		eq("p", got.data[1].compose_project)
		eq(nil, got.data[2].compose_project)
	end)
end)

describe("docker.list_networks", function()
	it("reports the labels of every network as a string", function()
		if vim.fn.executable("docker") == 0 then
			return
		end
		local result
		docker.list_networks(function(res)
			result = res
		end)
		vim.wait(15000, function()
			return result ~= nil
		end, 50)
		truthy(result, "docker never answered")
		if not result.ok then
			return -- no daemon on this machine
		end
		for _, network in ipairs(result.data) do
			eq("string", type(network.labels), network.name)
		end
	end)
end)
