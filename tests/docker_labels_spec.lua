local docker = require("dockyard.core.docker")

describe("docker.attach_image_labels", function()
	local stdout = table.concat({
		'{"id":"sha256:c1d2e3f4a5b6deadbeef","labels":{"com.docker.compose.project":"filow-docs","x":"y"}}',
		'{"id":"sha256:0123456789abcdef","labels":null}',
		"not json",
		'{"id":"sha256:aaaaaaaaaaaa1111","labels":{"org.opencontainers.image.source":"x"}}',
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
