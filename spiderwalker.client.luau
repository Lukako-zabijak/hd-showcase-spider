-- Connected Discord-Github
-- procedural wall walking spider by lukayield on discord and YieldForever on roblox
--!strict

local replicatedstorage = game:GetService("ReplicatedStorage") -- holds the mesh templates the spider is assembled from
local players = game:GetService("Players") -- source of the local player the spider follows
local runservice = game:GetService("RunService") -- source of the per frame signal that drives the whole simulation
local userinputservice = game:GetService("UserInputService") -- source of the clicks, taps and keys that place waypoints

local rideheight = 3.2 -- how far the body floats off the surface, tall enough that the knees can rise above it
local femurlength = 4.4 -- upper leg bone, shorter than the tibia so the knee folds high like a real spider
local tibialength = 5.6 -- lower leg bone, the sum of both bones is the furthest a foot can ever be from its hip
local hipradius = 1.5 -- hips sit on a ring this far from the body centre so legs do not start inside each other
local stanceradius = 6.2 -- feet rest on a wider ring so the body is carried inside a stable footprint
local legangles = { 38, 72, 108, 142 } -- degrees from straight ahead for the four legs of one side, mirrored front to back
local walkspeed = 14 -- studs per second at full stride, close to a player so it can keep up
local turnrate = 3.2 -- radians per second the heading may swing, capped so turns read as steps and not as a spin
local acceleration = 6 -- how sharply speed eases toward its target, higher would look robotic
local slowradius = 5 -- distance over which the spider brakes before a goal so it does not overshoot
local stepdistance = 2.4 -- how far the body may carry a rest spot from where its foot was last aimed before that foot has to step
local restdistance = 0.7 -- tighter limit while standing so the legs shuffle back into a tidy stance
local panicfactor = 2.2 -- a foot this many limits away steps even out of turn so a leg never overstretches
local steptime = 0.16 -- seconds one swing lasts, short enough that half the legs can always carry the body
local steplead = 0.09 -- extra seconds of travel aimed past the rest spot so a fresh foot lands ahead of the body
local steplift = 1.5 -- peak height of a swing so feet clear small bumps instead of dragging through them
local probelift = 3 -- footholds are searched from this far above the surface so a rising slope is not missed
local probedrop = 4.5 -- and down to this far below it so a foot can reach into a dip or over a ledge
local bodyradius = 1.4 -- size of the sphere swept ahead of the body to keep it out of walls
local bellyclearance = 2.6 -- least gap kept under the body centre so the abdomen never drags over a rock
local skin = 0.4 -- extra sweep length so the body stops short of a surface instead of touching it
local pressweight = 3 -- how many footholds a surface blocking the body is worth when choosing which way is up
local leanrange = 8 -- within this distance of the goal the goal's own surface also gets a say in which way is up
local tiltsharpness = 9 -- how quickly the body leans to match the ground under its feet
local heightsharpness = 10 -- how quickly the body settles to its ride height
local bobstiffness = 180 -- spring that pulls the footfall bob back to rest
local bobdamping = 16 -- under critical on purpose so the body rebounds once after each footfall
local landkick = 1.1 -- downward speed every landing foot adds to that spring
local scanrays = 16 -- directions searched for a wall when the goal is overhead
local scanrange = 80 -- how far each of those rays looks
local detourreset = 3 -- a goal that moves further than this makes the old detour stale
local followdistance = 11 -- how close it comes to the player, far enough that its legs never reach them
local arrivedistance = 1.5 -- how close it comes to a clicked waypoint
local maxstep = 1 / 20 -- longest time step simulated, a frame hitch would otherwise throw the body through a wall

local minreach = math.abs(femurlength - tibialength) + 0.05 -- a triangle of the two bones cannot close any tighter than this
local maxreach = femurlength + tibialength - 0.05 -- or open any wider, the margin stops the leg locking dead straight, where the knee direction becomes unstable
local cylinderturn = CFrame.Angles(0, math.pi / 2, 0) -- the marker cylinder runs along its x axis but lookalong aims the z axis, this swaps them
local gravity = workspace.Gravity -- reuse the place gravity so a falling spider matches every other falling object
local glow = Color3.fromRGB(255, 72, 40) -- same accent as the neon pieces of the meshes, reused for the marker
local meshes = replicatedstorage:WaitForChild("spidermeshes") -- unrigged meshparts modelled for this script, cloned once per piece

type piece = { name: string, offset: CFrame } -- a mesh template and where its centre sits in the frame that carries it

local bodypieces: { piece } = { -- the importer recentres every mesh on its bounding box, these offsets put the modelled pivots back
	{ name = "body", offset = CFrame.new(0, 1.424, 2.1119) }, -- armoured shell, modelled around the same body centre the solver uses
	{ name = "bodyglow", offset = CFrame.new(0, 1.4819, 1.145) }, -- eyes and seams are their own mesh because neon is a whole part material
}
local legpieces: { piece } = { -- in the order pose writes them, the first rides the femur bone and the other two ride the tibia bone
	{ name = "femur", offset = CFrame.new(0, 0.1834, -0.0025) }, -- modelled exactly as long as femurlength, joint centre to joint centre
	{ name = "tibia", offset = CFrame.new(0, 0.327, 0.3562) }, -- modelled as long as tibialength, ending in the claw
	{ name = "tibiaglow", offset = CFrame.new(0, 0.0708, -0.6007) }, -- claw tip and shin lights, so footfalls are easy to follow
}

local function safeunit(vector: Vector3, fallback: Vector3): Vector3 -- guards every normalise in the file
	return if vector.Magnitude > 1e-4 then vector.Unit else fallback -- the unit of a zero vector is nan and one nan cframe hides every part
end

local function clonepiece(spec: piece, parent: Instance): BasePart -- the one place a template name becomes a live part
	local part = meshes:WaitForChild(spec.name):Clone() :: BasePart -- templates are stored anchored and set to ignore collisions, queries and touches, so foothold rays never land on the spider
	part.Parent = parent -- parented after cloning so the copy enters the world in one step
	return part
end

local function findfoothold(frame: CFrame, hip: Vector3, desired: Vector3, params: RaycastParams): (Vector3, Vector3, boolean) -- returns position, surface normal and whether a surface was found
	local up = frame.UpVector -- every probe is relative to the body so the same three rays work on a wall or ceiling
	local raised = desired + up * probelift -- start above the wanted spot because the spot itself may be inside a slope
	local below = desired - up * probedrop -- a point under the wanted spot, used when there is no ground there at all
	local under = frame.Position - up * (rideheight + 0.75) -- a point just inside the surface the body is standing on
	local hit = workspace:Raycast(hip, raised - hip, params) -- first from the hip outward, this catches a wall between body and foot
		or workspace:Raycast(raised, -up * (probelift + probedrop), params) -- then straight down, the usual case on open ground
		or workspace:Raycast(below, under - below, params) -- then from below back inward, this wraps a foot around a ledge
	if hit then -- whichever probe hit first wins, they are ordered from most to least likely to matter
		return hit.Position, hit.Normal, true -- the normal is kept so the body can lean to match the surface
	end
	return desired, up, false -- no surface in reach, hang the foot at its rest spot and report it as not carrying weight
end

local leg = {} -- class table, one instance per leg
leg.__index = leg -- failed lookups on an instance fall through to the methods stored here

type legfields = { -- everything one leg remembers between frames
	direction: Vector3, -- unit vector from body centre toward this leg in body space
	hip: Vector3, -- where the femur attaches in body space
	home: Vector3, -- rest spot of the foot in body space
	group: number, -- which half of the gait this leg belongs to
	slot: number, -- index of this leg's first part in the spider's part list
	aim: Vector3, -- world position the last step was aimed at, before the probes moved it onto a surface
	planted: Vector3, -- world position the foot holds or is swinging to
	normal: Vector3, -- surface normal at that position
	grounded: boolean, -- false while that position is only empty air
	stepping: boolean, -- true during a swing
	clock: number, -- swing progress from zero to one
	from: Vector3, -- where the current swing started
	fromnormal: Vector3, -- surface normal where it started
	foot: Vector3, -- where the foot is drawn this frame
}
type legobject = typeof(setmetatable({} :: legfields, leg)) -- instance type that also knows the methods

function leg.new(direction: Vector3, group: number, slot: number, frame: CFrame, params: RaycastParams): legobject -- direction, gait group and part slot are all that differ between legs, hip and rest spot are derived from the direction
	local hip = direction * hipradius + Vector3.new(0, 0, -0.4) -- shifted with the thorax so the legs leave its sides
	local home = direction * stanceradius + Vector3.new(0, -rideheight, -0.4) -- same shift, dropped to the surface the body rides above
	local planted, normal, grounded = findfoothold(frame, frame * hip, frame * home, params) -- start standing on real ground instead of stepping in from nowhere
	return setmetatable({ -- attach the class table so method calls resolve through index
		direction = direction,
		hip = hip,
		home = home,
		group = group,
		slot = slot,
		aim = frame * home,
		planted = planted,
		normal = normal,
		grounded = grounded,
		stepping = false,
		clock = 0,
		from = planted,
		fromnormal = normal,
		foot = planted,
	}, leg)
end

function leg.step(self: legobject, frame: CFrame, desired: Vector3, params: RaycastParams): () -- starts a swing toward a new foothold
	self.from = self.foot -- swing from where the foot is drawn so a step never starts with a pop
	self.fromnormal = self.normal -- kept so the swing can lift away from both the old and the new surface
	self.aim = desired -- remembered so the next step is judged by how far the body has moved, not by how far the probes had to shift this foothold
	self.planted, self.normal, self.grounded = findfoothold(frame, frame * self.hip, desired, params) -- the landing spot is fixed now so the foot cannot slide once it is down
	self.stepping = true -- from now on advance moves the foot instead of the world holding it
	self.clock = 0 -- restart the swing timer
end

function leg.advance(self: legobject, dt: number, up: Vector3): boolean -- moves a swinging foot and reports true on the frame it lands
	self.clock = math.min(self.clock + dt / steptime, 1) -- progress as a fraction so the curves below do not depend on frame rate
	local ease = self.clock * self.clock * (3 - 2 * self.clock) -- smoothstep, the foot leaves and lands with zero speed
	local arc = safeunit(self.fromnormal + self.normal, up) * steplift * math.sin(math.pi * self.clock) -- lift away from both surfaces so a foot rounds a corner without clipping it
	self.foot = self.from:Lerp(self.planted, ease) + arc -- blend from start to landing spot and add the lift on top
	self.stepping = self.clock < 1 -- the swing ends exactly on the stored foothold
	return not self.stepping -- tells the body a foot just landed
end

function leg.pose(self: legobject, frame: CFrame, cframes: { CFrame }): () -- solves the two bones for the current foot and writes the three part cframes
	local hip = frame * self.hip -- hip in world space for this frame
	local reach = self.foot - hip -- the span the two bones have to cover
	local distance = math.clamp(reach.Magnitude, minreach, maxreach) -- outside this range the bones cannot form a triangle and the square root below would return nan
	local direction = safeunit(reach, -frame.UpVector) -- straight down from the body is the fallback when the foot sits exactly on the hip
	local cosine = (femurlength ^ 2 + distance ^ 2 - tibialength ^ 2) / (2 * femurlength * distance) -- law of cosines gives the angle at the hip between the foot line and the femur
	local sine = math.sqrt(1 - cosine * cosine) -- same angle as a sine without a second trig call
	local pole = safeunit(frame.UpVector - direction * frame.UpVector:Dot(direction), frame.LookVector) -- the part of body up that is square to the foot line, so the knee always bends away from the surface
	local knee = hip + (direction * cosine + pole * sine) * femurlength -- rotate the femur off the foot line by that angle inside the bend plane
	local toe = knee + safeunit(self.foot - knee, direction) * tibialength -- drawn at bone length so an out of reach foot shows as a straight leg, not a stretched one
	local hinge = direction:Cross(pole) -- the knee axis, square to both bones, crossing it with a bone gives that bone's outward side
	local femurframe = CFrame.lookAt((hip + knee) / 2, knee, hinge:Cross(knee - hip)) -- bone frame at the midpoint, z runs along the bone and y is square to it inside the bend plane, so the armour faces away from the bend
	local tibiaframe = CFrame.lookAt((knee + toe) / 2, toe, hinge:Cross(toe - knee)) -- same construction for the lower bone
	cframes[self.slot] = femurframe * legpieces[1].offset -- each mesh is shifted from the bone centre to its own bounding box centre
	cframes[self.slot + 1] = tibiaframe * legpieces[2].offset -- the tibia mesh and its glow share one frame
	cframes[self.slot + 2] = tibiaframe * legpieces[3].offset -- the glow shares the tibia frame so it stays locked to the claw
end

local spider = {} -- class table for the whole creature
spider.__index = spider -- same lookup fall through as the leg class

type spiderfields = { -- everything the body remembers between frames
	parts: { BasePart }, -- every piece in a fixed order
	cframes: { CFrame }, -- matching targets, written each frame and applied in one call
	legs: { legobject }, -- all eight, in left and right pairs from front to back
	params: RaycastParams, -- shared filter for every spatial query the spider makes
	position: Vector3, -- body centre
	up: Vector3, -- body up, follows the surface under the feet
	heading: Vector3, -- body forward, always kept square to up
	speed: number, -- current speed along the heading
	fallspeed: number, -- downward speed while too few feet have grip
	detour: Vector3?, -- a point to walk toward first when the goal cannot be reached along the current surface
	steep: boolean, -- whether the surface being walked on counts as a wall
	detoursteep: boolean, -- whether the detour was chosen while on a wall
	detourgoal: Vector3, -- the goal it was chosen for
	bob: number, -- footfall spring offset along up
	bobvelocity: number, -- speed of that spring
}
type spiderobject = typeof(setmetatable({} :: spiderfields, spider)) -- instance type that also knows the methods

function spider.new(origin: Vector3, params: RaycastParams): spiderobject -- builds the parts and the eight legs around a start position
	local model = Instance.new("Model") -- one container keeps the explorer tidy and makes the whole spider one object to find
	model.Name = "spider" -- named so it is easy to find while testing
	local parts: { BasePart } = {} -- filled in the exact order the frame loop writes cframes
	for _, spec in bodypieces do -- body meshes first so their indices match bodypieces
		table.insert(parts, clonepiece(spec, model)) -- cloned in list order so index and piece stay matched
	end
	local frame = CFrame.new(origin) -- starts upright and facing along negative z
	local legs: { legobject } = {} -- each leg remembers where its three parts start in the list above
	for pair, degrees in legangles do -- front pair first, so pair one sits at the head
		for side = -1, 1, 2 do -- left then right, so each pair is mirrored across the body
			local angle = math.rad(degrees) -- the trig functions take radians
			local direction = Vector3.new(side * math.sin(angle), 0, -math.cos(angle)) -- negative z is forward for a cframe
			table.insert(legs, leg.new(direction, (pair + (side + 1) / 2) % 2, #parts + 1, frame, params)) -- neighbours and mirror twins get opposite groups, so each group is a stable set of four
			for _, spec in legpieces do -- femur, tibia and glow, in the order pose writes them
				table.insert(parts, clonepiece(spec, model)) -- appended right after the leg was told this is where its parts start
			end
		end
	end
	model.Parent = workspace -- parented once everything is built so the world never shows a half made spider
	return setmetatable({ -- same pattern as the leg constructor
		parts = parts,
		cframes = table.create(#parts, CFrame.identity), -- sized once so no frame ever allocates a new list
		legs = legs,
		params = params,
		position = origin,
		up = Vector3.yAxis,
		heading = frame.LookVector,
		speed = 0,
		fallspeed = 0,
		detour = nil,
		steep = false,
		detoursteep = false,
		detourgoal = origin,
		bob = 0,
		bobvelocity = 0,
	}, spider)
end

function spider.translate(self: spiderobject, move: Vector3): Vector3? -- moves the body without letting it enter geometry and reports what blocked it
	local distance = move.Magnitude -- needed both to normalise the move and to size the sweep
	if distance < 1e-4 then -- also avoids dividing by zero below
		return nil -- a zero length move has no direction to sweep along
	end
	local hit = workspace:Spherecast(self.position, bodyradius, move / distance * (distance + skin), self.params) -- sweep a sphere, a thin ray would slip past corners the body is too wide for
	if hit then -- something is in the way
		move -= hit.Normal * math.min(move:Dot(hit.Normal), 0) -- drop only the part heading into the surface, so the body slides along a wall instead of stopping dead
	end
	self.position += move -- apply whatever part of the move survived
	return if hit then hit.Normal else nil -- lets the caller know which surface, if any, the body is pressed against
end

function spider.scan(self: spiderobject, goal: Vector3, depth: number): Vector3? -- looks around for a wall that could lead to a goal that is off this surface
	local origin = self.position + self.up * depth / 2 -- look from halfway up to the goal, so only things tall enough to help are seen
	local best: Vector3? = nil -- nothing found yet
	local bestdistance = math.huge -- so the first hit always wins the comparison
	for index = 1, scanrays do -- evenly spaced all the way round
		local direction = CFrame.fromAxisAngle(self.up, index / scanrays * 2 * math.pi):VectorToWorldSpace(self.heading) -- fan the rays out in the plane of the surface being walked on
		local hit = workspace:Raycast(origin, direction * scanrange, self.params) -- anything hit at this height is tall enough to be worth climbing
		local gap = if hit then (hit.Position - goal).Magnitude else math.huge -- a miss can never beat a real candidate
		if hit and gap < bestdistance then -- the wall nearest the goal is the shortest way to it
			best, bestdistance = hit.Position, gap -- remember the closest candidate so far
		end
	end
	return best -- nil when nothing climbable is in range, the caller then simply waits below
end

function spider.steer(self: spiderobject, goal: Vector3?, stopdistance: number, dt: number): () -- turns the heading and sets the speed toward a goal, including detours round obstacles
	local targetspeed = 0 -- standing still unless a goal further down says otherwise
	if goal then -- there is no goal while the player has no character
		local offset = goal - self.position -- straight line to the goal, usually through geometry
		local depth = offset:Dot(self.up) -- how far the goal sits along body up
		local flat = offset - self.up * depth -- flatten onto the surface being walked on, so a goal up a wall still gives a direction along the floor
		local distance = flat.Magnitude -- how far there is left to walk along this surface
		local above = depth + rideheight -- signed height of the goal over this surface, zero when it lies on it
		local reach = stopdistance / 2 -- how far off the surface a goal may be and still count as on it, tight for a clicked point and loose for a player whose root floats above the floor
		local tilt = math.abs(self.up.Y) -- one on a floor or ceiling, zero on a vertical wall
		if tilt < 0.5 or tilt > 0.85 then -- clearly a wall or clearly level
			self.steep = tilt < 0.5 -- only a clear reading changes the answer, a body leaning over an edge keeps the kind of surface it came from
		end
		local steep = self.steep -- true on walls, false on floors and ceilings
		local detour = self.detour -- local copy so the checks below can clear or replace it
		local aside = if detour then detour - self.position else Vector3.zero -- where the detour lies relative to the body
		aside -= self.up * aside:Dot(self.up) -- only the direction along the surface matters, the foothold probes handle any climb on the way
		if detour then -- an active detour is only ever ended here, never swapped midway
			local arrived = steep ~= self.detoursteep or aside.Magnitude < 1 -- crossed between wall and level ground, or standing on the detour point itself
			if arrived or math.abs(above) <= reach or (goal - self.detourgoal).Magnitude > detourreset then -- any one of these makes the detour pointless
				detour = nil -- the detour has done its job, or the goal is now on this surface, or the goal moved
			end
		else -- no detour yet, check whether the goal needs one
			if -above > math.max(distance, reach) then -- more behind the surface than along it
				detour = self.position + self.heading * scanrange -- the goal is behind this surface, so commit to walking straight on until an edge leads round to it
			elseif above > reach and distance <= (if steep then stopdistance else above) then -- the goal is out in the open off this surface and walking along it cannot get closer
				detour = if steep then self.position - Vector3.yAxis * scanrange else self:scan(goal, depth) -- from a wall head down to open ground, from ground or ceiling find a wall that leads to the goal
			end
			self.detoursteep, self.detourgoal = steep, goal -- remember the conditions it was chosen under so the checks above can tell when it is done
		end
		self.detour = detour -- store the result for the next frame
		local wanted: Vector3? = nil -- stays nil once the spider is as close as it can get
		if detour then -- a detour always outranks the direct line
			wanted = safeunit(aside, self.heading) -- fall back to straight ahead when already on top of the point
		elseif distance > stopdistance then -- normal case, the goal can be reached along this surface
			wanted = flat / distance -- unit vector toward it
		end
		if wanted then -- only turn and speed up when there is somewhere to go
			local angle = math.atan2(self.heading:Cross(wanted):Dot(self.up), self.heading:Dot(wanted)) -- signed angle about body up, atan2 keeps the sign that acos would lose
			local turn = math.clamp(angle, -turnrate * dt, turnrate * dt) -- limited per frame so it turns by walking round
			self.heading = CFrame.fromAxisAngle(self.up, turn):VectorToWorldSpace(self.heading) -- rotate about body up so the turn is correct on any surface
			local facing = math.max(self.heading:Dot(wanted), 0.1) -- slow right down while facing away so it turns on the spot instead of walking a wide arc
			targetspeed = walkspeed * facing * math.clamp((offset.Magnitude - stopdistance) / slowradius, 0.15, 1) -- ease off near the goal using the true distance, the floor value stops it crawling forever
		end
	end
	self.speed += (targetspeed - self.speed) * (1 - math.exp(-acceleration * dt)) -- exponential ease gives the same response at any frame rate
end

function spider.update(self: spiderobject, goal: Vector3?, stopdistance: number, dt: number): () -- one full simulation step, called once per rendered frame
	self:steer(goal, stopdistance, dt) -- decide heading and speed first, everything below reacts to them
	local velocity = self.heading * self.speed -- world velocity, also used to aim steps ahead
	local pressed = self:translate(velocity * dt) -- advance the body and learn whether a wall stopped it
	local frame = CFrame.fromMatrix(self.position, self.heading:Cross(self.up), self.up, -self.heading) -- build the body frame from its three axes, back is the negated heading

	local active: number? = nil -- the gait group that currently has feet in the air
	for _, limb in self.legs do -- first pass only finds out who is already swinging
		if limb.stepping then -- a leg in the air means its group has the turn
			active = limb.group -- only one group swings at once, so any stepping leg names it
		end
	end
	local limit = if self.speed > 1 then stepdistance else restdistance -- a full stride while walking, a much smaller tolerance while standing
	local forwardsum, rightsum, centersum, grounded = Vector3.zero, Vector3.zero, Vector3.zero, 0 -- running totals for the plane fit, filled in the same pass that updates the legs
	local normalsum = if pressed then pressed * pressweight else Vector3.zero -- a wall the body is pushing on counts like extra footholds on it, so the lean starts before enough feet get there
	if goal and (goal - self.position).Magnitude < leanrange then -- close enough that the last few steps decide how the body ends up sitting
		local sight = workspace:Raycast(self.position, (goal - self.position) * 1.2, self.params) -- look straight at the goal, a little past it so the surface it lies on is hit
		if sight and (sight.Position - goal).Magnitude < 1 then -- nothing is in between, so this really is the goal's own surface
			normalsum += sight.Normal * pressweight -- lean onto that surface, otherwise a body perched on a thin edge beside the goal never tips over onto it
		end
	end
	for _, limb in self.legs do -- second pass moves the legs and gathers the foothold data
		if limb.stepping then -- a swinging foot only needs its swing advanced
			if limb:advance(dt, self.up) then -- true on the frame the foot touches down
				self.bobvelocity -= landkick -- each footfall pushes the body down a little so the walk has weight
			end
		else
			local home = frame * limb.home -- where this foot would rest right now, in world space
			local drift = (limb.aim - home).Magnitude -- the foot stays put in the world, so this grows as the body walks away from where the step was aimed
			if drift > limit and (active == nil or active == limb.group or drift > limit * panicfactor) then -- only one group may swing at a time so the other four always carry the body
				active = active or limb.group -- claim the turn so the other group cannot also start this frame
				limb:step(frame, home + velocity * (steptime + steplead), self.params) -- aim where the rest spot will be when the swing ends, plus a lead
			end
		end
		forwardsum -= limb.planted * limb.direction.Z -- each foothold votes with its own body space offset, front feet pull this vector forward
		rightsum += limb.planted * limb.direction.X -- and right feet pull this one right, the offsets sum to zero so no centre is needed
		normalsum += limb.normal -- surface normals for the blend below
		centersum += limb.planted -- summed so the average gives the height of the footprint
		grounded += if limb.grounded then 1 else 0 -- count the feet that are actually holding on
	end

	local target = Vector3.yAxis -- with no grip the body rights itself toward world up
	if grounded >= 3 then -- three points define a plane, fewer cannot hold the body
		self.fallspeed = 0 -- any fall ends the moment the feet have grip
		local fitted = safeunit(rightsum:Cross(forwardsum), self.up) -- normal of the plane through the footholds, this is what pitches the body when front feet climb
		target = safeunit(fitted + safeunit(normalsum, self.up), self.up) -- blended with the surface normals, which react a step earlier at a corner
		local lift = (centersum / #self.legs - self.position):Dot(target) + rideheight -- how far the body is from its ride height above the footholds
		local belly = workspace:Raycast(self.position, -target * rideheight, self.params) -- the footholds can straddle a bump, so also look straight under the body
		if belly then -- nothing under the body means the footholds alone decide
			lift = math.max(lift, bellyclearance - belly.Distance) -- rise over whatever is under the belly even when the feet say stay low
		end
		self:translate(target * lift * (1 - math.exp(-heightsharpness * dt))) -- ease toward that height through the same sweep, so the correction cannot push the body into a ceiling
	else
		self.fallspeed += gravity * dt -- integrate gravity by hand since the parts are anchored
		self:translate(Vector3.yAxis * -self.fallspeed * dt) -- fall through the sweep too, so the body lands on things instead of passing through them
		if goal and self.position.Y < workspace.FallenPartsDestroyHeight then -- below the height where the engine destroys fallen parts
			self.position, self.fallspeed = goal + Vector3.yAxis * 12, 0 -- fell out of the world, drop back in above the goal
		end
	end
	self.up = safeunit(self.up:Lerp(target, 1 - math.exp(-tiltsharpness * dt)), self.up) -- lean gradually so a single new foothold cannot snap the body
	self.heading = safeunit(self.heading - self.up * self.heading:Dot(self.up), frame.RightVector:Cross(self.up)) -- remove any part along the new up, this is what carries the heading round a corner

	self.bobvelocity += (-bobstiffness * self.bob - bobdamping * self.bobvelocity) * dt -- damped spring, velocity first so the integration stays stable
	self.bob += self.bobvelocity * dt -- then position from the new velocity
	local visual = frame * CFrame.new(0, self.bob, 0) -- the bob only moves what is drawn, the simulated body stays smooth for the probes
	for index, spec in bodypieces do -- body meshes ride on the bobbing frame
		self.cframes[index] = visual * spec.offset -- body space offset turned into a world cframe
	end
	for _, limb in self.legs do -- legs are solved last because their hips move with the bob
		limb:pose(visual, self.cframes) -- each leg fills its own four slots
	end
	workspace:BulkMoveTo(self.parts, self.cframes, Enum.BulkMoveMode.FireCFrameChanged) -- one engine call for all parts, much cheaper than setting each cframe from luau
end

local player = players.LocalPlayer -- this runs on the client so the motion is smooth and never waits on replication
local camera = workspace.CurrentCamera :: Camera -- needed to turn a click into a world ray, the cast tells strict mode it always exists on the client
local params = RaycastParams.new() -- one filter object shared by every ray, sweep and click
params.FilterType = Enum.RaycastFilterType.Exclude -- ignore the listed instances and hit everything else
params.RespectCanCollide = true -- decoration a player can walk through should not hold a spider either

local function ignorecharacter(character: Model): () -- a named function so the same code serves the connection and the first character
	params:AddToFilter(character) -- the spider must walk past the player, not climb them
end
player.CharacterAdded:Connect(ignorecharacter) -- every respawn makes a new model that has to be ignored again
if player.Character then -- nil until the first spawn has finished
	ignorecharacter(player.Character) -- the first character can exist before this script runs
end

local start = (player.Character or player.CharacterAdded:Wait()):WaitForChild("HumanoidRootPart") :: BasePart -- wait so the spider can spawn relative to the player
local walker = spider.new(start.Position + start.CFrame.LookVector * 14, params) -- in front of the player so it is the first thing they see
local marker = Instance.new("Part") -- flat disc that shows the clicked goal, unparented until one exists
marker.Shape = Enum.PartType.Cylinder -- a thin cylinder reads as a disc
marker.Size = Vector3.new(0.3, 3.2, 3.2) -- thickness first because a cylinder runs along x
marker.Color = glow -- matches the spider's own lights
marker.Material = Enum.Material.Neon -- visible on any surface colour
marker.Anchored = true -- it only ever moves when a new goal is clicked
marker.CanCollide = false -- nothing should bump into a marker
marker.CanQuery = false -- clicks and foothold rays must pass through it
local waypoint: Vector3? = nil -- nil means follow the player

local function setwaypoint(screen: Vector2): () -- shared by mouse clicks and touch taps
	local ray = camera:ScreenPointToRay(screen.X, screen.Y) -- turn the pointer position into a world ray
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, params) -- same filter as the feet, so a goal is always on something walkable
	if hit then -- clicking the sky leaves the current goal alone
		waypoint = hit.Position -- the frame loop reads this on its next pass
		marker.CFrame = CFrame.lookAlong(hit.Position, hit.Normal) * cylinderturn -- lay the disc flat on whatever surface was clicked
		marker.Parent = workspace -- show the disc now that it has somewhere to be
	end
end

userinputservice.InputBegan:Connect(function(input: InputObject, processed: boolean): () -- mouse and keyboard arrive through the same signal
	if processed then -- true when the engine or a gui already used the input
		return -- the click or key was meant for chat or a button
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then -- left click places a waypoint
		setwaypoint(Vector2.new(input.Position.X, input.Position.Y)) -- the mouse position arrives as a vector3, only x and y are screen coordinates
	elseif input.KeyCode == Enum.KeyCode.F then -- f for follow
		waypoint = nil -- back to following the player
		marker.Parent = nil -- hide the disc without destroying it so it can be reused
	end
end)

userinputservice.TouchTapInWorld:Connect(function(position: Vector2, processed: boolean): () -- taps get their own signal so dragging the thumbstick never sets a goal
	if not processed then -- ignore taps that landed on a button
		setwaypoint(position) -- the tap position is already a screen point
	end
end)

runservice.PreRender:Connect(function(dt: number): () -- before each rendered frame so the pose is never a frame behind the camera
	local character = player.Character -- read each frame because respawning replaces it
	local root = character and character.PrimaryPart -- nil for a moment between respawns
	local goal = waypoint or if root then root.Position else nil -- a clicked waypoint outranks following
	walker:update(goal, if waypoint then arrivedistance else followdistance, math.min(dt, maxstep)) -- waypoints are approached closely, the player is given room, and the time step is capped
end)
