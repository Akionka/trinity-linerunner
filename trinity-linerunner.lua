local sampev = require 'samp.events'
local inspect = require 'inspect'
local encoding = require 'encoding'
encoding.default = 'UTF-8'
local cp = encoding.cp1251
local u8 = function (s) return cp:decode(s) end
local imgui = require 'mimgui'
local ffi = require 'ffi'
local vkeys = require 'vkeys'

local wm = require 'windows.message'
local new, str, sizeof = imgui.new, ffi.string, ffi.sizeof

local fcomp_default = function(a, b) return a < b end
function table.bininsert(t, value, fcomp) fcomp = fcomp or fcomp_default local iStart,iEnd,iMid,iState = 1,#t,1,0 while iStart <= iEnd do iMid = math.floor( (iStart+iEnd)/2 ) if fcomp( value,t[iMid] ) then iEnd,iState = iMid - 1,0 else iStart,iState = iMid + 1,1 end end table.insert( t,(iMid+iState),value ) return (iMid+iState) end
---@enum vehicle_model
local VEHICLE_MODEL = {
  YANKEE = 456, ---@type Model
}
---@enum dialog
local DIALOG = {
  ROUTES = 3360,
  GOODS_LIST = 3330,
  NO_SPACE_LEFT = 3331,
  GOODS_QUANTITY = 3332,
  GOODS_CONFIRM = 3334,
  GOODS_RETURN = 3350,
  GOODS_RETURN_CONFIRM = 3351,
  GOODS_SELL = 3370,
  INFORMATION = 45,
}
---@class good_type
---@field position integer Localized good type name
---@field name string Position in goods list when buying them
---@field purchase_price integer Price for buying goods
---@field sale_price integer Price for selling goods
---@field gives_bonus boolean Whether this good type gives bonus (every 100th sold goods of this or any other type that gives bonus)
local GoodType = {
  name = cp'Неизвестно',
  purchase_price = 0,
  sale_price = 0,
  gives_bonus = false,
}
---Good type constructor
---@param name string
---@param position integer
---@param purchase_price integer
---@param sale_price integer
---@param gives_bonus boolean
---@return good_type
function GoodType:new(name, position, purchase_price, sale_price, gives_bonus)
  local gt = {
    name = name,
    purchase_price = purchase_price,
    sale_price = sale_price,
    gives_bonus = gives_bonus,
  }
  setmetatable(gt, self)
  self.__index = self
  self.__tostring = function (self) return self.name end
  return gt
end

local GOOD_TYPE = {
  NONE = GoodType:new(cp'Нет', -1, 0, 0, false),
  PRODUCTS = GoodType:new(cp'Продукты', 0, 2, 5, true),
  FUR_ELECTRONICS = GoodType:new(cp'Мебель и электроника', 1 ,3, 5, true),
  AUTOPARTS = GoodType:new(cp'Автозапчасти', 2, 3, 5, true),
  WEAPONS = GoodType:new(cp'Оружие', 3, 3, 5, false),
  CLOTHES = GoodType:new(cp'Одежда', 4, 2, 5, true),
  MEDICINES = GoodType:new(cp'Лекарства', 5, 3, 5, true),
}
---Converts string to good type
---@param str string
---@return good_type
function GoodType.from_string(str)
  if str:find(cp'[Пп]родукт.*') then return GOOD_TYPE.PRODUCTS
  elseif str:find(cp'[Ээ]лектроник.*') or str:find(cp'[Мм]ебель.*') then return GOOD_TYPE.FUR_ELECTRONICS
  elseif str:find(cp'[Аа]втозапчаст.*') then return GOOD_TYPE.AUTOPARTS
  elseif str:find(cp'[Оо]ружи.*') then return GOOD_TYPE.WEAPONS
  elseif str:find(cp'[Оо]дежд.*') then return GOOD_TYPE.CLOTHES
  elseif str:find(cp'[Лл]екарств.*') then return GOOD_TYPE.MEDICINES
  else return GOOD_TYPE.NONE
  end
end
---@class position
---@field x number
---@field y number
---@field z number
---@generic T
---@class set<T>: table<T, boolean>
local Set = {}
---Set constructor
---@generic T
---@param values T[]?
---@return set<T>
function Set:new(values)
local set = {}
  setmetatable(set, self)
  self.__index = self
  if values then for _, v in ipairs(values) do set[v] = true end end
  return set
end
---Checks if set contains value
---@generic T
---@param value T
---@return boolean
function Set:has(value)
  return self[value] ~= nil
end
---Returns size of set
---@return integer
function Set:size()
  local size = 0
  for _ in pairs(self) do size = size + 1 end
  return size
end
---Adds value to set
---@generic T
---@param value T
function Set:add(value)
  self[value] = true
end
---@class business
---@field idx integer In-game business index
---@field name string In-game business name
---@field position position In-game business position
---@field good_type good_type
---@field required_goods integer?
---@field private blip Marker?
---@field private checkpoint Checkpoint?
---@field blip_shown ImBool
local Business = {
  name = '',
  position = {x = 0.0, y = 0.0, z = 0.0},
  good_type = GOOD_TYPE.NONE,
  required_goods = nil,
  blip = nil,
  checkpoint = nil,
  blip_shown = new.bool(false),
}
---Business constructor
---@param idx integer
---@param name string
---@param position position
---@param good_type good_type
---@return business
function Business:new(idx, name, position, good_type)
  local b = {
    idx = idx,
    name = name,
    position = position,
    good_type = good_type,
    blip_shown = new.bool(false),
  }

  setmetatable(b, self)
  self.__index = self
  return b
end
---Calculates distance to business
---@param dest position | business
---@return number
function Business:distance_to(dest)
  dest = dest.position or dest
  -- idk why but getDistanceBetweenCoords3d works 7 times slower than this, maybe it's because of JIT of something idk 4real :D
  return math.sqrt((self.position.x - dest.x) ^ 2 + (self.position.y - dest.y) ^ 2 + (self.position.z - dest.z) ^ 2)
end
---Calculates profit for selling N goods to business
---@param goods integer
---@return integer
function Business:profit(goods)
  return goods * (self.good_type.sale_price - self.good_type.purchase_price + (self.good_type.gives_bonus and 1 or 0) / 100)
end
---Creates business blip
function Business:create_blip()
  if not self.blip then
    self.blip = addSpriteBlipForCoord(self.position.x, self.position.y, self.position.z, 51)
    self.checkpoint = createCheckpoint(2, self.position.x, self.position.y, self.position.z, 0, 0, 0, 5)
  else
    self:remove_blip()
    self:create_blip()
  end
  self.blip_shown[0] = true
end
---Removes business blip
function Business:remove_blip()
  if self.blip then
    removeBlip(self.blip)
    deleteCheckpoint(self.checkpoint)
    self.blip = nil
    self.checkpoint = nil
    self.blip_shown[0] = false
  end
end
---Returns jsonEncode friendly table
---@return table
function Business:to_json()
  return {
    idx = self.idx,
    name = self.name,
    position = self.position,
    good_type = self.good_type:__tostring(),
  }
end
---@type business[]
--- This is a list of built-in businesses, current as of 09/01/2023 (after the Home Update)
--- The list is only used when the script is started for the first time (when there is no businesses.json file)
--- New businesses and changes to existing ones will be added automatically when you are near them
--- Businesses are saved in gtasa_folder/moonloader/config/trinity-linerunner/businesses.json
--- They are saved automatically when script is stopped by non-crash reason
--- They are automotically loaded when script is started
local businesses = {
  Business:new(001, cp'Магазин «US ammunation #1»', {x = 1368.900024, y = -1279.756958, z = 13.547000},GOOD_TYPE.WEAPONS),
  Business:new(002, cp'Ресторан «Little Italy»', {x = 1567.9530029297, y = -1898.0119628906, z = 14.66100025177},GOOD_TYPE.PRODUCTS),
  Business:new(006, cp'Бар «The Welcome Pump»', {x = 681.690002, y = -473.368011, z = 16.535999},GOOD_TYPE.PRODUCTS),
  Business:new(007, cp'Магазин «Discount Furniture #1»', {x = 985.818970, y = -1384.338989, z = 13.634000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(010, cp'Закусочная «Jim\'s Sticky Ring»', {x = 1038.204956, y = -1340.733032, z = 13.742000},GOOD_TYPE.PRODUCTS),
  Business:new(011, cp'Ночной клуб «Alhambra»', {x = 1836.985962, y = -1682.426025, z = 13.325000},GOOD_TYPE.PRODUCTS),
  Business:new(012, cp'Ночной клуб «Crystal»', {x = 816.197998, y = -1386.104004, z = 13.597000},GOOD_TYPE.PRODUCTS),
  Business:new(013, cp'Бар «Ten Green Bottles»', {x = 2310.084961, y = -1643.540039, z = 14.827000},GOOD_TYPE.PRODUCTS),
  Business:new(014, cp'Клуб «Pig Pen»', {x = 2421.553955, y = -1219.244995, z = 25.561001},GOOD_TYPE.PRODUCTS),
  Business:new(015, cp'Мотель «Jefferson»', {x = 2233.291992, y = -1159.812012, z = 25.891001},GOOD_TYPE.NONE),
  Business:new(016, cp'Отель «Hilton»', {x = 1568.838013, y = -1334.579956, z = 16.483999},GOOD_TYPE.NONE),
  Business:new(020, cp'Мотель «Tee Pee #1»', {x = -830.278015, y = 1442.374023, z = 14.060000},GOOD_TYPE.NONE),
  Business:new(023, cp'Офис сети торговых автоматов US', {x = 1324.185059, y = 286.157990, z = 20.045000},GOOD_TYPE.PRODUCTS),
  Business:new(024, cp'Аэропорт Сан-Фиерро', {x = -1544.009033, y = -441.285004, z = 6.000000},GOOD_TYPE.NONE),
  Business:new(027, cp'Мотель «Montgomery\'s»', {x = 1311.714966, y = 228.779007, z = 19.555000},GOOD_TYPE.NONE),
  Business:new(028, cp'Спортзал «Ganton GYM»', {x = 2229.978027, y = -1721.345947, z = 13.562000},GOOD_TYPE.NONE),
  Business:new(035, cp'Отель «Quebrados»', {x = -1465.708984, y = 2611.876953, z = 56.180000},GOOD_TYPE.NONE),
  Business:new(036, cp'Магазин «RC ammunation #2»', {x = -1508.911011, y = 2610.699951, z = 55.835999},GOOD_TYPE.WEAPONS),
  Business:new(037, cp'Спортзал «Marital Arts»', {x = -2270.646973, y = -155.970993, z = 35.320000},GOOD_TYPE.NONE),
  Business:new(038, cp'Магазин «AF ammunation #1»', {x = -2625.916016, y = 208.244003, z = 4.813000},GOOD_TYPE.WEAPONS),
  Business:new(039, cp'Отель «Biffin bridge»', {x = -2463.488037, y = 131.794006, z = 35.172001},GOOD_TYPE.NONE),
  Business:new(040, cp'Кафе «Central Perk»', {x = -1817.767944, y = 1115.491943, z = 45.438000},GOOD_TYPE.PRODUCTS),
  Business:new(043, cp'Магазин «Discount Furniture #2»', {x = -1872.109985, y = 1141.406982, z = 45.445000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(049, cp'Закусочная «Tuff Nutt»', {x = -2767.867920, y = 788.786987, z = 52.780998},GOOD_TYPE.PRODUCTS),
  Business:new(053, cp'Прокат «SF Boats»', {x = -1923.666016, y = 1374.843018, z = 7.188000},GOOD_TYPE.NONE),
  Business:new(054, cp'Магазин «RC ammunation #3»', {x = -745.856018, y = 1590.435059, z = 26.983000},GOOD_TYPE.WEAPONS),
  Business:new(055, cp'Секс-шоп «Nude & XXX #2»', {x = -2431.281006, y = -82.946999, z = 35.319000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(058, cp'Ресторан «Tanuki»', {x = -2240.564941, y = 578.044983, z = 35.172001},GOOD_TYPE.PRODUCTS),
  Business:new(060, cp'Ночной клуб «Jizzy»', {x = -2624.608887, y = 1412.741943, z = 7.094000},GOOD_TYPE.PRODUCTS),
  Business:new(061, cp'Закусочная «Juniper»', {x = -2524.503906, y = 1216.112061, z = 37.671001},GOOD_TYPE.PRODUCTS),
  Business:new(062, cp'Аэропорт Лос-Сантос', {x = 1956.733032, y = -2183.634033, z = 13.547000},GOOD_TYPE.NONE),
  Business:new(063, cp'Офис сети торговых автоматов AF', {x = -1815.068970, y = 1078.609985, z = 46.082001},GOOD_TYPE.PRODUCTS),
  Business:new(064, cp'Магазин «US ammunation #2»', {x = 2400.438965, y = -1981.989990, z = 13.547000},GOOD_TYPE.WEAPONS),
  Business:new(065, cp'Отель «Vang Hoff in the park»', {x = -2426.229004, y = 338.048004, z = 36.992001},GOOD_TYPE.NONE),
  Business:new(073, cp'Бар «Lonely Miner»', {x = -1440.581055, y = 2611.679932, z = 55.984001},GOOD_TYPE.PRODUCTS),
  Business:new(074, cp'Закусочная «King Ring»', {x = -144.098999, y = 1225.206055, z = 19.899000},GOOD_TYPE.PRODUCTS),
  Business:new(075, cp'Таверна «Lil Probe»', {x = -89.611000, y = 1378.234985, z = 10.470000},GOOD_TYPE.PRODUCTS),
  Business:new(077, cp'Магазин «US ammunation #3»', {x = 1357.036011, y = 308.079987, z = 19.747000},GOOD_TYPE.WEAPONS),
  Business:new(081, cp'Закусочная «Steakhouse»', {x = 1693.229980, y = 2209.094971, z = 11.069000},GOOD_TYPE.PRODUCTS),
  Business:new(082, cp'Бар «The Craw»', {x = 2441.177002, y = 2065.479980, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(083, cp'Секс-шоп «XXX #1»', {x = 2515.282959, y = 2297.372070, z = 10.820000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(085, cp'Мотель «Snowstorm»', {x = 2463.464111, y = 1406.108032, z = 10.906000},GOOD_TYPE.NONE),
  Business:new(086, cp'Отель «Visage»', {x = 2016.973999, y = 1913.062988, z = 12.334000},GOOD_TYPE.NONE),
  Business:new(088, cp'Магазин «RC ammunation #1»', {x = 2556.913086, y = 2065.373047, z = 11.100000},GOOD_TYPE.WEAPONS),
  Business:new(089, cp'Офис сети торговых автоматов RC', {x = 1504.515991, y = 2363.641113, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(090, cp'Магазин «Discount Furniture #3»', {x = 2811.000977, y = 1987.728027, z = 10.820000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(091, cp'Прокат «Bayside Boats»', {x = -2188.647949, y = 2413.680908, z = 5.156000},GOOD_TYPE.NONE),
  Business:new(092, cp'Ресторан «Metropolia»', {x = 2172.024902, y = 2120.204102, z = 10.828000},GOOD_TYPE.PRODUCTS),
  Business:new(093, cp'Спортзал «Below The Belt»', {x = 1968.796997, y = 2295.873047, z = 16.455999},GOOD_TYPE.NONE),
  Business:new(099, cp'Казино «Caligula\'s Palace»', {x = 2196.961914, y = 1677.149048, z = 12.367000},GOOD_TYPE.PRODUCTS),
  Business:new(100, cp'Казино «4 Dragons»', {x = 2019.336060, y = 1007.703979, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(101, cp'Казино «Lemon»', {x = 1658.500000, y = 2250.062012, z = 11.070000},GOOD_TYPE.PRODUCTS),
  Business:new(102, cp'Аэропорт Лас-Вентурас', {x = 1715.171997, y = 1616.822998, z = 10.033000},GOOD_TYPE.NONE),
  Business:new(105, cp'Ночной клуб «Vintage»', {x = 2507.330078, y = 1242.254028, z = 10.827000},GOOD_TYPE.PRODUCTS),
  Business:new(106, cp'Клуб «Nude Strippers»', {x = 2543.311035, y = 1025.240967, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(109, cp'Бар «Monti\'s Pick»', {x = 1244.683960, y = 205.350998, z = 19.645000},GOOD_TYPE.PRODUCTS),
  Business:new(110, cp'Магазин «LV Uniform»', {x = 2085.792969, y = 2486.248047, z = 11.078000},GOOD_TYPE.CLOTHES),
  Business:new(111, cp'Магазин «Robоi\'s 24 / 7 #1»', {x = 1315.529053, y = -897.682983, z = 39.577999},GOOD_TYPE.PRODUCTS),
  Business:new(112, cp'Магазин «Unity 24 / 7»', {x = 1833.771973, y = -1842.562012, z = 13.578000},GOOD_TYPE.PRODUCTS),
  Business:new(113, cp'Магазин «Beach 24 / 7»', {x = 388.015015, y = -1897.207031, z = 7.836000},GOOD_TYPE.PRODUCTS),
  Business:new(114, cp'Магазин «Highway 24 / 7»', {x = 24.503000, y = -2646.648926, z = 40.464001},GOOD_TYPE.PRODUCTS),
  Business:new(115, cp'Магазин «Whetstone 24 / 7»', {x = -1562.604004, y = -2733.025879, z = 48.743000},GOOD_TYPE.PRODUCTS),
  Business:new(116, cp'Магазин «Central 24 / 7»', {x = -2442.660889, y = 755.418030, z = 35.172001},GOOD_TYPE.PRODUCTS),
  Business:new(117, cp'Магазин «Corner\'s 24 / 7»', {x = -1857.457031, y = 1115.439941, z = 45.445000},GOOD_TYPE.PRODUCTS),
  Business:new(118, cp'Магазин «Juniper 24 / 7»', {x = -2374.199951, y = 933.979980, z = 45.422001},GOOD_TYPE.PRODUCTS),
  Business:new(119, cp'Магазин «North Strip 24 / 7»', {x = 2097.626953, y = 2224.700928, z = 11.023000},GOOD_TYPE.PRODUCTS),
  Business:new(120, cp'Магазин «Starfish 24 / 7»', {x = 2194.937988, y = 1991.003052, z = 12.297000},GOOD_TYPE.PRODUCTS),
  Business:new(121, cp'Магазин «Escalante 24 / 7»', {x = 2247.697021, y = 2396.290039, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(122, cp'Магазин «Robоi\'s 24 / 7 #2»', {x = 1352.343994, y = -1759.250000, z = 13.508000},GOOD_TYPE.PRODUCTS),
  Business:new(123, cp'Магазин «General 24 / 7»', {x = 2546.620117, y = 1972.661011, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(124, cp'Магазин «Market 24 / 7»', {x = 994.320007, y = -1295.578003, z = 13.547000},GOOD_TYPE.PRODUCTS),
  Business:new(125, cp'Магазин «Desert 24 / 7»', {x = 663.117004, y = 1716.338013, z = 7.188000},GOOD_TYPE.PRODUCTS),
  Business:new(126, cp'Магазин «Los Flores 24 / 7»', {x = 2701.000000, y = -1279.687012, z = 58.945000},GOOD_TYPE.PRODUCTS),
  Business:new(127, cp'Магазин «Ganton 24 / 7»', {x = 2424.250000, y = -1742.766968, z = 13.546000},GOOD_TYPE.PRODUCTS),
  Business:new(128, cp'Магазин «Palomino\'s 24 / 7»', {x = 2318.866943, y = -88.696999, z = 26.483999},GOOD_TYPE.PRODUCTS),
  Business:new(130, cp'Магазин «Bayside 24 / 7»', {x = -2518.737061, y = 2318.706055, z = 4.984000},GOOD_TYPE.PRODUCTS),
  Business:new(131, cp'Магазин «El Quebrados 24 / 7»', {x = -1266.508057, y = 2715.872070, z = 50.265999},GOOD_TYPE.PRODUCTS),
  Business:new(132, cp'Магазин «Las Barrancas 24 / 7»', {x = -818.200989, y = 1560.521973, z = 27.117001},GOOD_TYPE.PRODUCTS),
  Business:new(133, cp'Магазин «Fort Carson 24 / 7»', {x = -205.070999, y = 1183.239014, z = 19.742001},GOOD_TYPE.PRODUCTS),
  Business:new(134, cp'Магазин «Angel Pine 24 / 7»', {x = -2103.547119, y = -2431.936035, z = 30.625000},GOOD_TYPE.PRODUCTS),
  Business:new(135, cp'Магазин «Montgomery\'s 24 / 7»', {x = 1310.984009, y = 330.031006, z = 19.914000},GOOD_TYPE.PRODUCTS),
  Business:new(136, cp'Магазин «Las Payasadas 24 / 7»', {x = -242.830994, y = 2711.955078, z = 62.688000},GOOD_TYPE.PRODUCTS),
  Business:new(137, cp'Магазин «Hippy\'s 24 / 7»', {x = -2511.320068, y = -49.890999, z = 25.617001},GOOD_TYPE.PRODUCTS),
  Business:new(138, cp'Магазин «Queen\'s 24 / 7»', {x = -2596.279053, y = 448.356995, z = 14.609000},GOOD_TYPE.PRODUCTS),
  Business:new(139, cp'Магазин «South 24 / 7»', {x = -2016.781982, y = -34.008999, z = 35.266998},GOOD_TYPE.PRODUCTS),
  Business:new(140, cp'Магазин «Airport\'s 24 / 7»', {x = 1686.548950, y = -2237.531982, z = -2.716000},GOOD_TYPE.PRODUCTS),
  Business:new(141, cp'Магазин «Blueberry\'s 24 / 7»', {x = 244.884003, y = -55.439999, z = 1.578000},GOOD_TYPE.PRODUCTS),
  Business:new(142, cp'Закусочная «Burger Shot #1»', {x = 1199.312988, y = -918.137024, z = 43.123001},GOOD_TYPE.PRODUCTS),
  Business:new(143, cp'Закусочная «Burger Shot #2»', {x = 810.489014, y = -1616.183960, z = 13.547000},GOOD_TYPE.PRODUCTS),
  Business:new(144, cp'Закусочная «Burger Shot #3»', {x = -2355.820068, y = 1008.101990, z = 50.897999},GOOD_TYPE.PRODUCTS),
  Business:new(145, cp'Закусочная «Burger Shot #4»', {x = -1912.431030, y = 827.911011, z = 35.230000},GOOD_TYPE.PRODUCTS),
  Business:new(146, cp'Закусочная «Burger Shot #5»', {x = -2336.864014, y = -166.776001, z = 35.555000},GOOD_TYPE.PRODUCTS),
  Business:new(147, cp'Закусочная «Burger Shot #6»', {x = 1157.918945, y = 2072.274902, z = 11.063000},GOOD_TYPE.PRODUCTS),
  Business:new(148, cp'Закусочная «Burger Shot #7»', {x = 1872.260010, y = 2071.912109, z = 11.063000},GOOD_TYPE.PRODUCTS),
  Business:new(149, cp'Закусочная «Burger Shot #8»', {x = 2367.056885, y = 2071.071045, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(150, cp'Закусочная «Burger Shot #9»', {x = 2472.864990, y = 2034.155029, z = 11.063000},GOOD_TYPE.PRODUCTS),
  Business:new(151, cp'Закусочная «Burger Shot #10»', {x = 2169.406982, y = 2795.957031, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(152, cp'Закусочная «Cluckin\' Bell #1»', {x = 2397.861084, y = -1899.187988, z = 13.547000},GOOD_TYPE.PRODUCTS),
  Business:new(153, cp'Закусочная «Cluckin\' Bell #2»', {x = 2419.750977, y = -1509.000000, z = 24.000000},GOOD_TYPE.PRODUCTS),
  Business:new(154, cp'Закусочная «Cluckin\' Bell #3»', {x = 928.914978, y = -1352.951050, z = 13.344000},GOOD_TYPE.PRODUCTS),
  Business:new(155, cp'Закусочная «Cluckin\' Bell #4»', {x = -2155.298096, y = -2460.145020, z = 30.851999},GOOD_TYPE.PRODUCTS),
  Business:new(156, cp'Закусочная «Cluckin\' Bell #5»', {x = -2671.764893, y = 257.928986, z = 4.633000},GOOD_TYPE.PRODUCTS),
  Business:new(157, cp'Закусочная «Cluckin\' Bell #6»', {x = -1816.693970, y = 618.684021, z = 35.172001},GOOD_TYPE.PRODUCTS),
  Business:new(158, cp'Закусочная «Cluckin\' Bell #7»', {x = -1213.823975, y = 1830.360962, z = 41.930000},GOOD_TYPE.PRODUCTS),
  Business:new(159, cp'Закусочная «Cluckin\' Bell #8»', {x = 172.988007, y = 1177.177002, z = 14.758000},GOOD_TYPE.PRODUCTS),
  Business:new(160, cp'Закусочная «Cluckin\' Bell #9»', {x = 2101.893066, y = 2228.844971, z = 11.023000},GOOD_TYPE.PRODUCTS),
  Business:new(161, cp'Закусочная «Cluckin\' Bell #10»', {x = 2393.189941, y = 2041.558960, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(162, cp'Закусочная «Cluckin\' Bell #11»', {x = 2638.517090, y = 1671.855957, z = 11.023000},GOOD_TYPE.PRODUCTS),
  Business:new(163, cp'Закусочная «Cluckin\' Bell #12»', {x = 2838.193115, y = 2407.678955, z = 11.069000},GOOD_TYPE.PRODUCTS),
  Business:new(164, cp'Закусочная «Well Stacked Pizza #1»', {x = 1367.546021, y = 248.261993, z = 19.566999},GOOD_TYPE.PRODUCTS),
  Business:new(165, cp'Закусочная «Well Stacked Pizza #2»', {x = 2331.809082, y = 75.047997, z = 26.621000},GOOD_TYPE.PRODUCTS),
  Business:new(166, cp'Закусочная «Well Stacked Pizza #3»', {x = -1720.953003, y = 1359.723999, z = 7.185000},GOOD_TYPE.PRODUCTS),
  Business:new(167, cp'Закусочная «Well Stacked Pizza #4»', {x = -1808.711060, y = 945.918030, z = 24.891001},GOOD_TYPE.PRODUCTS),
  Business:new(168, cp'Закусочная «Well Stacked Pizza #5»', {x = 2083.356934, y = 2224.699951, z = 11.023000},GOOD_TYPE.PRODUCTS),
  Business:new(169, cp'Закусочная «Well Stacked Pizza #6»', {x = 2638.788086, y = 1849.803955, z = 11.023000},GOOD_TYPE.PRODUCTS),
  Business:new(170, cp'Закусочная «Well Stacked Pizza #7»', {x = 2756.797119, y = 2477.319092, z = 11.063000},GOOD_TYPE.PRODUCTS),
  Business:new(171, cp'Закусочная «Well Stacked Pizza #8»', {x = 203.466995, y = -201.936996, z = 1.578000},GOOD_TYPE.PRODUCTS),
  Business:new(172, cp'Закусочная «Well Stacked Pizza #9»', {x = 2105.481934, y = -1806.531006, z = 13.555000},GOOD_TYPE.PRODUCTS),
  Business:new(173, cp'Закусочная «Well Stacked Pizza #10»', {x = 1730.333008, y = -2335.497070, z = 13.547000},GOOD_TYPE.PRODUCTS),
  Business:new(174, cp'Прокат «LS Limousine»', {x = 1020.289001, y = -1350.777954, z = 13.552000},GOOD_TYPE.NONE),
  Business:new(175, cp'Прокат «SF Limousine»', {x = -2694.543945, y = -30.826000, z = 4.336000},GOOD_TYPE.NONE),
  Business:new(176, cp'Прокат «LV Limousine»', {x = 2129.672119, y = 1403.415039, z = 11.133000},GOOD_TYPE.NONE),
  Business:new(177, cp'Прокат «LS Boats»', {x = 718.721985, y = -1476.209961, z = 5.469000},GOOD_TYPE.NONE),
  Business:new(178, cp'Магазин «Discount Furniture #4»', {x = 2485.189941, y = -1958.748047, z = 13.581000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(179, cp'Магазин «Discount Furniture #5»', {x = 1986.167969, y = -1283.477051, z = 23.966000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(180, cp'Магазин «Discount Furniture #6»', {x = 2304.070068, y = 56.282001, z = 26.476999},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(181, cp'Магазин «Discount Furniture #7»', {x = -2128.152100, y = 643.640015, z = 52.367001},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(182, cp'Магазин «Discount Furniture #8»', {x = -2439.558105, y = -195.576004, z = 35.313000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(183, cp'Магазин «Discount Furniture #9»', {x = -2182.902100, y = -2337.091064, z = 30.625000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(184, cp'Магазин «Discount Furniture #10»', {x = 1556.843018, y = 951.630005, z = 10.820000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(185, cp'Магазин «Discount Furniture #11»', {x = 1879.196045, y = 2339.430908, z = 10.980000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(186, cp'Магазин «Discount Furniture #12»', {x = -2485.628906, y = 2272.778076, z = 4.984000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(188, cp'Бар «China Town»', {x = -2129.641113, y = 711.330994, z = 69.563004},GOOD_TYPE.PRODUCTS),
  Business:new(189, cp'Бар «Misty\'s»', {x = -2242.143066, y = -88.189003, z = 35.320000},GOOD_TYPE.PRODUCTS),
  Business:new(191, cp'Бар «Liquor»', {x = 2348.604004, y = -1372.681030, z = 24.398001},GOOD_TYPE.PRODUCTS),
  Business:new(192, cp'Клуб «Legal»', {x = 1283.708984, y = -1161.255005, z = 23.961000},GOOD_TYPE.PRODUCTS),
  Business:new(193, cp'Бар «J & J»', {x = -2103.596924, y = -2342.106934, z = 30.617001},GOOD_TYPE.PRODUCTS),
  Business:new(194, cp'Закусочная «Mexican Food #1»', {x = 2354.594971, y = -1511.581055, z = 24.000000},GOOD_TYPE.PRODUCTS),
  Business:new(195, cp'Прокат «Desert Racing»', {x = 541.343994, y = 2362.664063, z = 30.870001},GOOD_TYPE.NONE),
  Business:new(196, cp'Секс-шоп «XXX #2»', {x = 1087.614014, y = -922.481995, z = 43.390999},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(197, cp'Магазин «Willowfield 24 / 7»', {x = 2424.464111, y = -1921.906982, z = 13.544000},GOOD_TYPE.PRODUCTS),
  Business:new(198, cp'Бар «Big Mo»', {x = 293.334015, y = -195.477005, z = 1.779000},GOOD_TYPE.PRODUCTS),
  Business:new(199, cp'Магазин DS #1', {x = 454.197998, y = -1477.969971, z = 30.813999},GOOD_TYPE.CLOTHES),
  Business:new(200, cp'Магазин DS #2', {x = 1642.322998, y = -2280.685059, z = -1.195000},GOOD_TYPE.CLOTHES),
  Business:new(201, cp'Магазин DS #3', {x = -2156.058105, y = 420.674988, z = 35.172001},GOOD_TYPE.CLOTHES),
  Business:new(202, cp'Магазин Victim #1', {x = 2803.011963, y = 2430.627930, z = 11.063000},GOOD_TYPE.CLOTHES),
  Business:new(203, cp'Магазин Victim #2', {x = -1694.536987, y = 951.861023, z = 24.891001},GOOD_TYPE.CLOTHES),
  Business:new(204, cp'Магазин Victim #3', {x = 461.674011, y = -1500.793945, z = 31.046000},GOOD_TYPE.CLOTHES),
  Business:new(205, cp'Магазин Sub Urban #1', {x = 2112.865967, y = -1211.473999, z = 23.962999},GOOD_TYPE.CLOTHES),
  Business:new(206, cp'Магазин Sub Urban #2', {x = -2489.867920, y = -29.107000, z = 25.617001},GOOD_TYPE.CLOTHES),
  Business:new(207, cp'Магазин Sub Urban #3', {x = 2779.704102, y = 2453.874023, z = 11.063000},GOOD_TYPE.CLOTHES),
  Business:new(208, cp'Магазин Prolaps #1', {x = 499.377991, y = -1360.564941, z = 16.368000},GOOD_TYPE.CLOTHES),
  Business:new(209, cp'Магазин Prolaps #2', {x = 2826.243896, y = 2407.263916, z = 11.063000},GOOD_TYPE.CLOTHES),
  Business:new(210, cp'Магазин ZIP #1', {x = 2090.477051, y = 2224.700928, z = 11.023000},GOOD_TYPE.CLOTHES),
  Business:new(211, cp'Магазин ZIP #2', {x = 2572.145996, y = 1904.937012, z = 11.023000},GOOD_TYPE.CLOTHES),
  Business:new(212, cp'Магазин ZIP #3', {x = -1882.240967, y = 866.468994, z = 35.172001},GOOD_TYPE.CLOTHES),
  Business:new(213, cp'Магазин ZIP #4', {x = 1456.635986, y = -1137.525024, z = 23.951000},GOOD_TYPE.CLOTHES),
  Business:new(214, cp'Магазин Binco #1', {x = 2244.311035, y = -1665.542969, z = 15.477000},GOOD_TYPE.CLOTHES),
  Business:new(215, cp'Магазин Binco #2', {x = -2373.775879, y = 910.132019, z = 45.445000},GOOD_TYPE.CLOTHES),
  Business:new(216, cp'Магазин Binco #3', {x = 1657.036987, y = 1733.337036, z = 10.828000},GOOD_TYPE.CLOTHES),
  Business:new(217, cp'Магазин Binco #4', {x = 2101.892090, y = 2257.438965, z = 11.023000},GOOD_TYPE.CLOTHES),
  Business:new(218, cp'Бар «El pueblo»', {x = 2151.128906, y = -1013.924988, z = 62.729000},GOOD_TYPE.PRODUCTS),
  Business:new(219, cp'Автозаправка #1', {x = 2117.479004, y = 896.776001, z = 11.180000},GOOD_TYPE.NONE),
  Business:new(220, cp'Автозаправка #2', {x = 2637.310059, y = 1129.677979, z = 11.180000},GOOD_TYPE.NONE),
  Business:new(221, cp'Автозаправка #3', {x = 639.057007, y = 1683.354004, z = 7.188000},GOOD_TYPE.NONE),
  Business:new(222, cp'Автозаправка #4', {x = -1320.459961, y = 2698.660889, z = 50.265999},GOOD_TYPE.NONE),
  Business:new(223, cp'Автозаправка #5', {x = -2420.156006, y = 969.869019, z = 45.297001},GOOD_TYPE.NONE),
  Business:new(224, cp'Автозаправка #6', {x = -1676.146973, y = 432.213989, z = 7.180000},GOOD_TYPE.NONE),
  Business:new(225, cp'Автозаправка #7', {x = -2231.461914, y = -2558.264893, z = 31.922001},GOOD_TYPE.NONE),
  Business:new(226, cp'Автозаправка #8', {x = -1623.550049, y = -2693.206055, z = 48.743000},GOOD_TYPE.NONE),
  Business:new(227, cp'Автозаправка #9', {x = 1928.592041, y = -1776.296997, z = 13.547000},GOOD_TYPE.NONE),
  Business:new(228, cp'Автозаправка #10', {x = -78.400002, y = -1169.958008, z = 2.135000},GOOD_TYPE.NONE),
  Business:new(229, cp'Автозаправка #11', {x = 1383.338013, y = 465.519012, z = 20.191999},GOOD_TYPE.NONE),
  Business:new(230, cp'Автозаправка #12', {x = 661.359985, y = -571.482971, z = 16.336000},GOOD_TYPE.NONE),
  Business:new(231, cp'Автозаправка #13', {x = -1465.744995, y = 1873.421021, z = 32.632999},GOOD_TYPE.NONE),
  Business:new(232, cp'Автозаправка #14', {x = 2150.656982, y = 2733.865967, z = 11.176000},GOOD_TYPE.NONE),
  Business:new(233, cp'Автозаправка #15', {x = 2187.730957, y = 2469.657959, z = 11.242000},GOOD_TYPE.NONE),
  Business:new(234, cp'Автозаправка #16', {x = 1599.104980, y = 2221.833984, z = 11.063000},GOOD_TYPE.NONE),
  Business:new(235, cp'Автозаправка #17', {x = 1009.083984, y = -929.513977, z = 42.327999},GOOD_TYPE.NONE),
  Business:new(236, cp'Закусочная «Hobos»', {x = 875.565979, y = -968.776001, z = 37.188000},GOOD_TYPE.PRODUCTS),
  Business:new(237, cp'Бар «Cactus»', {x = -179.684006, y = 1087.521973, z = 19.742001},GOOD_TYPE.PRODUCTS),
  Business:new(238, cp'Магазин «Discount Furniture #13»', {x = -145.755005, y = 1172.396973, z = 19.742001},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(240, cp'Магазин «RC ammunation #4»', {x = -316.156006, y = 829.929993, z = 14.242000},GOOD_TYPE.WEAPONS),
  Business:new(242, cp'Бар «Fleisch Beer»', {x = 2333.020996, y = -17.284000, z = 26.483999},GOOD_TYPE.PRODUCTS),
  Business:new(243, cp'Магазин «US ammunation #4»', {x = 243.294998, y = -178.343994, z = 1.582000},GOOD_TYPE.WEAPONS),
  Business:new(244, cp'Магазин «AF ammunation #2»', {x = -2093.650879, y = -2464.949951, z = 30.625000},GOOD_TYPE.WEAPONS),
  Business:new(247, cp'Прокат «LV Boats»', {x = -1384.365967, y = 2115.923096, z = 42.200001},GOOD_TYPE.NONE),
  Business:new(253, cp'Ресторан «Rodeo Drive»', {x = 419.815002, y = -1428.483032, z = 32.485001},GOOD_TYPE.PRODUCTS),
  Business:new(254, cp'Секс-шоп «Nude & XXX #1»', {x = 1940.020020, y = -2115.941895, z = 13.695000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(258, cp'Казино «Emerald Isle»', {x = 2127.528076, y = 2380.114014, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(259, cp'Казино «Old Strip»', {x = 2441.229980, y = 2163.863037, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(260, cp'Казино «Royal»', {x = 2089.993896, y = 1451.623047, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(261, cp'Казино «Treasure Island»', {x = 1965.046997, y = 1623.234009, z = 12.862000},GOOD_TYPE.PRODUCTS),
  Business:new(262, cp'Магазин «LS Uniform»', {x = 1163.168945, y = -1585.250000, z = 13.547000},GOOD_TYPE.CLOTHES),
  Business:new(263, cp'Магазин «SF Uniform»', {x = -2269.539063, y = -47.512001, z = 35.320000},GOOD_TYPE.CLOTHES),
  Business:new(265, cp'Закусочная «Smokin\' Beef Grill»', {x = -857.995972, y = 1535.383057, z = 22.587000},GOOD_TYPE.PRODUCTS),
  Business:new(266, cp'Ночной клуб «Gaydar Station»', {x = -2550.950928, y = 193.886993, z = 6.227000},GOOD_TYPE.PRODUCTS),
  Business:new(267, cp'Прокат «LS Foodtruck»', {x = 452.339996, y = -1796.551025, z = 5.547000},GOOD_TYPE.NONE),
  Business:new(268, cp'Прокат «SF Foodtruck»', {x = -2501.899902, y = 745.729004, z = 35.015999},GOOD_TYPE.NONE),
  Business:new(269, cp'Прокат «LV Foodtruck»', {x = 2106.030029, y = 2046.439941, z = 10.820000},GOOD_TYPE.NONE),
  Business:new(270, cp'Отель «Carson City»', {x = -206.729004, y = 1086.980957, z = 19.742001},GOOD_TYPE.NONE),
  Business:new(271, cp'Отель «Angel Pine»', {x = -2144.267090, y = -2425.295898, z = 30.625000},GOOD_TYPE.NONE),
  Business:new(272, cp'Мотель «Ghetto Low Rates»', {x = 2357.814941, y = -1990.560059, z = 13.547000},GOOD_TYPE.NONE),
  Business:new(273, cp'Отель «Radisson»', {x = -1749.324951, y = 868.463013, z = 25.086000},GOOD_TYPE.NONE),
  Business:new(274, cp'Отель «Holiday Inn»', {x = -1826.515015, y = -222.940994, z = 18.375000},GOOD_TYPE.NONE),
  Business:new(275, cp'Отель «Baymont Inn»', {x = 487.230988, y = -1639.102051, z = 23.702999},GOOD_TYPE.NONE),
  Business:new(276, cp'Отель «4 seasons»', {x = 1015.276978, y = -1548.385010, z = 14.859000},GOOD_TYPE.NONE),
  Business:new(277, cp'Мотель «Green River»', {x = 178.289993, y = -94.974998, z = 1.549000},GOOD_TYPE.NONE),
  Business:new(278, cp'Отель «Hampton»', {x = -2510.538086, y = 2277.791992, z = 4.984000},GOOD_TYPE.NONE),
  Business:new(279, cp'Бар «Green Lumberjack»', {x = -793.187012, y = 1481.904053, z = 22.566999},GOOD_TYPE.PRODUCTS),
  Business:new(281, cp'Отель «Back o Beyond»', {x = -286.354004, y = -2150.708984, z = 29.306000},GOOD_TYPE.NONE),
  Business:new(282, cp'Автозаправка #18', {x = -736.093018, y = 2747.844971, z = 47.227001},GOOD_TYPE.NONE),
  Business:new(283, cp'Мотель «Tee Pee #2»', {x = -846.653015, y = 2748.688965, z = 45.852001},GOOD_TYPE.NONE),
  Business:new(284, cp'Автозаправка #19', {x = 59.007999, y = 1221.962036, z = 18.867001},GOOD_TYPE.NONE),
  Business:new(285, cp'Магазин DS #4', {x = 2080.343994, y = 2122.863037, z = 10.820000},GOOD_TYPE.CLOTHES),
  Business:new(286, cp'Закусочная «Well Stacked Pizza #11»', {x = 2351.823975, y = 2533.628906, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(287, cp'Магазин «RC ammunation #5»', {x = 776.721985, y = 1871.416992, z = 4.907000},GOOD_TYPE.WEAPONS),
  Business:new(288, cp'Магазин «US ammunation #5»', {x = 2333.084961, y = 61.634998, z = 26.705999},GOOD_TYPE.WEAPONS),
  Business:new(289, cp'Магазин «RC ammunation #6»', {x = 2159.544922, y = 943.177979, z = 10.820000},GOOD_TYPE.WEAPONS),
  Business:new(290, cp'Бар «Castillo del diablo»', {x = -376.919006, y = 2242.320068, z = 42.618000},GOOD_TYPE.PRODUCTS),
  Business:new(291, cp'Закусочная «Jay\'s»', {x = -1942.112061, y = 2379.386963, z = 49.702999},GOOD_TYPE.PRODUCTS),
  Business:new(295, cp'Мастерская «PAY N SPRAY #1»', {x = 723.367981, y = -463.071014, z = 16.336000},GOOD_TYPE.AUTOPARTS),
  Business:new(296, cp'Мастерская «PAY N SPRAY #2»', {x = -1427.207031, y = 2591.622070, z = 55.835999},GOOD_TYPE.AUTOPARTS),
  Business:new(297, cp'Мастерская «PAY N SPRAY #3»', {x = -93.301003, y = 1110.951050, z = 19.742001},GOOD_TYPE.AUTOPARTS),
  Business:new(298, cp'Мастерская «PAY N SPRAY #4»', {x = 2072.010010, y = -1836.853027, z = 13.555000},GOOD_TYPE.AUTOPARTS),
  Business:new(299, cp'Мастерская «PAY N SPRAY #5»', {x = -2431.219971, y = 1028.686035, z = 50.390999},GOOD_TYPE.AUTOPARTS),
  Business:new(300, cp'Мастерская «PAY N SPRAY #6»', {x = 1967.703003, y = 2158.260986, z = 10.820000},GOOD_TYPE.AUTOPARTS),
  Business:new(301, cp'Мастерская «PAY N SPRAY #7»', {x = 485.272003, y = -1733.807007, z = 11.094000},GOOD_TYPE.AUTOPARTS),
  Business:new(302, cp'Мастерская «PAY N SPRAY #8»', {x = 1028.527954, y = -1029.883057, z = 32.089001},GOOD_TYPE.AUTOPARTS),
  Business:new(303, cp'Мастерская «PAY N SPRAY #9»', {x = -1908.864014, y = 277.227997, z = 41.047001},GOOD_TYPE.AUTOPARTS),
  Business:new(304, cp'Мастерская «PAY N SPRAY #10»', {x = 2399.333008, y = 1482.876953, z = 10.820000},GOOD_TYPE.AUTOPARTS),
  Business:new(305, cp'Автозаправка #20', {x = -2032.975952, y = 161.429993, z = 29.046000},GOOD_TYPE.NONE),
  Business:new(306, cp'Магазин «Dillimore 24 / 7»', {x = 670.278992, y = -553.672974, z = 16.336000},GOOD_TYPE.PRODUCTS),
  Business:new(310, cp'Грузовой терминал US', {x = 123.317001, y = -298.377991, z = 1.578000},GOOD_TYPE.NONE),
  Business:new(311, cp'Грузовой терминал AF', {x = -525.513977, y = -506.454010, z = 25.523001},GOOD_TYPE.NONE),
  Business:new(312, cp'Грузовой терминал RC', {x = 1713.308960, y = 1048.639038, z = 10.820000},GOOD_TYPE.NONE),
  Business:new(313, cp'Отель «Las Payasadas»', {x = -217.550995, y = 2690.416992, z = 63.000000},GOOD_TYPE.NONE),
  Business:new(314, cp'Бар «Las Payasadas»', {x = -271.671997, y = 2691.666016, z = 62.688000},GOOD_TYPE.PRODUCTS),
  Business:new(315, cp'Магазин «RC ammunation #7»', {x = -212.544006, y = 2643.895020, z = 63.014000},GOOD_TYPE.WEAPONS),
  Business:new(316, cp'Клуб «Las Payasadas»', {x = -227.386993, y = 2711.955078, z = 62.977001},GOOD_TYPE.PRODUCTS),
  Business:new(317, cp'Магазин часов «Tableau»', {x = 562.112000, y = -1506.712036, z = 14.549000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(318, cp'Магазин часов «Yars Jewelry»', {x = 1699.930054, y = -1171.279053, z = 23.847000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(319, cp'Магазин часов «East Beach»', {x = 2712.925049, y = -1468.953979, z = 30.563999},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(320, cp'Магазин часов «Pier 69»', {x = -1617.645996, y = 1147.437988, z = 7.188000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(321, cp'Магазин часов «Red Star»', {x = -2185.451904, y = 579.293030, z = 35.172001},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(322, cp'Магазин часов «Brown Embassy»', {x = -2511.022949, y = -101.748001, z = 25.617001},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(323, cp'Магазин часов «Emerald»', {x = 2062.623047, y = 2308.752930, z = 10.820000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(324, cp'Магазин часов «Piligrim»', {x = 2455.854980, y = 1722.868042, z = 10.820000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(325, cp'Магазин часов «Trublot»', {x = 1555.734985, y = 1073.751953, z = 10.820000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(326, cp'Похоронное бюро LS', {x = 940.723022, y = -1085.275024, z = 24.296000},GOOD_TYPE.NONE),
  Business:new(327, cp'Похоронное бюро SF', {x = -2590.589111, y = 13.332000, z = 4.328000},GOOD_TYPE.NONE),
  Business:new(328, cp'Похоронное бюро LV', {x = 1397.010010, y = 765.562988, z = 10.842000},GOOD_TYPE.NONE),
  Business:new(329, cp'Частный клуб «Chabanais»', {x = -2285.316895, y = 829.296021, z = 57.169998},GOOD_TYPE.PRODUCTS),
  Business:new(330, cp'Частный клуб «Sphinx»', {x = -2491.145996, y = -109.260002, z = 25.617001},GOOD_TYPE.PRODUCTS),
  Business:new(331, cp'Частный клуб «Big Sister»', {x = -1874.003052, y = -218.197998, z = 18.375000},GOOD_TYPE.PRODUCTS),
  Business:new(332, cp'Частный клуб «One Two Two»', {x = -1643.129028, y = 1172.917969, z = 7.188000},GOOD_TYPE.PRODUCTS),
  Business:new(333, cp'Частный клуб «The Site»', {x = -2546.770996, y = 392.494995, z = 22.016001},GOOD_TYPE.PRODUCTS),
  Business:new(334, cp'Частный клуб «Centaurus»', {x = -1911.173950, y = 1190.223999, z = 45.452999},GOOD_TYPE.PRODUCTS),
  Business:new(335, cp'Частный клуб «Nana»', {x = -2685.064941, y = 820.669983, z = 49.984001},GOOD_TYPE.PRODUCTS),
  Business:new(336, cp'Частный клуб «China Sauna Club»', {x = -2102.379883, y = 579.289001, z = 35.174999},GOOD_TYPE.PRODUCTS),
  Business:new(337, cp'Частный клуб «Club LV»', {x = -2214.739014, y = 198.093002, z = 35.320000},GOOD_TYPE.PRODUCTS),
  Business:new(338, cp'Частный клуб «Ginza Club»', {x = -2545.946045, y = 1213.317993, z = 37.422001},GOOD_TYPE.PRODUCTS),
  Business:new(339, cp'Садовый магазин «Bub\'s Hardware #3»', {x = 2332.846924, y = -67.261002, z = 26.483999},GOOD_TYPE.PRODUCTS),
  Business:new(340, cp'Садовый магазин «Bub\'s Hardware #1»', {x = 691.862976, y = -583.533997, z = 16.336000},GOOD_TYPE.PRODUCTS),
  Business:new(341, cp'Садовый магазин «Bub\'s Hardware #2»', {x = 272.885010, y = -158.089005, z = 1.741000},GOOD_TYPE.PRODUCTS),
  Business:new(343, cp'Общественная душевая US #1', {x = 1347.984985, y = -1501.453979, z = 13.547000},GOOD_TYPE.PRODUCTS),
  Business:new(344, cp'Общественная душевая US #2', {x = 2404.569092, y = -1548.682007, z = 24.164000},GOOD_TYPE.PRODUCTS),
  Business:new(345, cp'Общественная душевая US #3', {x = 349.239014, y = -1346.785034, z = 14.508000},GOOD_TYPE.PRODUCTS),
  Business:new(346, cp'Общественная душевая AF #1', {x = -2431.410889, y = -114.919998, z = 35.320000},GOOD_TYPE.PRODUCTS),
  Business:new(347, cp'Общественная душевая AF #2', {x = -2157.559082, y = 627.205994, z = 52.382999},GOOD_TYPE.PRODUCTS),
  Business:new(348, cp'Общественная душевая AF #3', {x = -1582.587036, y = 956.072998, z = 7.188000},GOOD_TYPE.PRODUCTS),
  Business:new(349, cp'Общественная душевая RC #1', {x = 1541.765991, y = 1120.171021, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(350, cp'Общественная душевая RC #2', {x = 2417.745117, y = 1430.614990, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(351, cp'Общественная душевая RC #3', {x = 1887.796021, y = 2408.701904, z = 11.178000},GOOD_TYPE.PRODUCTS),
  Business:new(352, cp'Магазин «Aquarius»', {x = 1086.698975, y = -1270.727051, z = 13.547000},GOOD_TYPE.PRODUCTS),
  Business:new(353, cp'Магазин «Nautilus»', {x = 2424.079102, y = -1955.010010, z = 13.547000},GOOD_TYPE.PRODUCTS),
  Business:new(354, cp'Магазин «Neptunus»', {x = -2334.488037, y = -60.523998, z = 35.320000},GOOD_TYPE.PRODUCTS),
  Business:new(355, cp'Магазин «Portunus»', {x = -1714.141968, y = 1269.048950, z = 7.180000},GOOD_TYPE.PRODUCTS),
  Business:new(356, cp'Магазин «Saturnus»', {x = -206.714005, y = 1212.126953, z = 19.891001},GOOD_TYPE.PRODUCTS),
  Business:new(357, cp'Магазин «Platypus»', {x = 2055.845947, y = 2046.171997, z = 11.058000},GOOD_TYPE.PRODUCTS),
  Business:new(359, cp'Клуб «Nude XXX»', {x = 2506.816895, y = 2120.279053, z = 10.840000},GOOD_TYPE.PRODUCTS),
  Business:new(360, cp'Клуб «Obi Wan»', {x = -2239.608887, y = 721.739990, z = 49.414001},GOOD_TYPE.PRODUCTS),
  Business:new(361, cp'Клуб «Noir»', {x = -1697.510010, y = 883.646973, z = 24.898001},GOOD_TYPE.PRODUCTS),
  Business:new(363, cp'Тату-салон «Idlewood»', {x = 2068.581055, y = -1779.837036, z = 13.560000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(364, cp'Тату-салон «LS Fashions»', {x = 1072.310059, y = -1221.313965, z = 16.891001},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(365, cp'Тату-салон «Hemlock»', {x = -2490.993896, y = -38.926998, z = 25.617001},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(366, cp'Тату-салон «Old Sailor»', {x = -1775.119995, y = 1331.848999, z = 7.180000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(367, cp'Тату-салон «Redsands»', {x = 2094.760010, y = 2122.864990, z = 10.820000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(368, cp'Тату-салон «Fort Carson»', {x = -206.024994, y = 1053.477051, z = 19.733999},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(369, cp'Аптека «Glen Park»', {x = 1836.515015, y = -1445.032959, z = 13.596000},GOOD_TYPE.MEDICINES),
  Business:new(370, cp'Аптека «Market Station»', {x = 887.776001, y = -1385.386963, z = 13.506000},GOOD_TYPE.MEDICINES),
  Business:new(371, cp'Аптека «Montgomery»', {x = 1235.360962, y = 361.027008, z = 19.385000},GOOD_TYPE.MEDICINES),
  Business:new(372, cp'Аптека «Carson Drugstore»', {x = -179.093002, y = 1177.541016, z = 19.891001},GOOD_TYPE.MEDICINES),
  Business:new(373, cp'Аптека «Roca Escalante»', {x = 2537.044922, y = 2259.819092, z = 10.820000},GOOD_TYPE.MEDICINES),
  Business:new(374, cp'Аптека «Strip Pharmacy»', {x = 2232.603027, y = 1490.090942, z = 10.755000},GOOD_TYPE.MEDICINES),
  Business:new(375, cp'Аптека «Garcia Drugstore»', {x = -2156.766113, y = -5.237000, z = 35.299999},GOOD_TYPE.MEDICINES),
  Business:new(376, cp'Аптека «Esplanade»', {x = -1889.983032, y = 1294.509033, z = 7.180000},GOOD_TYPE.MEDICINES),
  Business:new(377, cp'Аптека «Angel Pine»', {x = -2177.990967, y = -2400.532959, z = 30.625000},GOOD_TYPE.MEDICINES),
  Business:new(378, cp'Мастерская «PAY N SPRAY #11»', {x = -2104.245117, y = -2246.043945, z = 30.625000},GOOD_TYPE.AUTOPARTS),
  Business:new(379, cp'Спортзал «Santa Maria GYM»', {x = 675.156982, y = -1869.714966, z = 5.461000},GOOD_TYPE.NONE),
  Business:new(380, cp'Магазин Prolaps #3', {x = -2586.562988, y = 147.246994, z = 4.336000},GOOD_TYPE.CLOTHES),
  Business:new(381, cp'Магазин «AF ammunation #3»', {x = -2715.377930, y = 1307.857056, z = 7.108000},GOOD_TYPE.WEAPONS),
  Business:new(382, cp'Туристический магазин «East Beach»', {x = 2747.514893, y = -1629.229980, z = 13.013000},GOOD_TYPE.PRODUCTS),
  Business:new(383, cp'Туристический магазин «Mad Tourist»', {x = 1074.692993, y = -1293.208984, z = 13.547000},GOOD_TYPE.PRODUCTS),
  Business:new(384, cp'Туристический магазин «Forester»', {x = -2174.928955, y = -2324.949951, z = 30.625000},GOOD_TYPE.PRODUCTS),
  Business:new(385, cp'Туристический магазин «Around The World»', {x = -2280.163086, y = 654.424011, z = 49.445000},GOOD_TYPE.PRODUCTS),
  Business:new(386, cp'Туристический магазин «Das Tourist»', {x = 2271.007080, y = 2293.818115, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(387, cp'Туристический магазин «Bedouin»', {x = -1458.041016, y = 2589.975098, z = 55.995998},GOOD_TYPE.PRODUCTS),
  Business:new(388, cp'Ломбард «Antique»', {x = 1667.623047, y = -1568.016968, z = 13.547000},GOOD_TYPE.NONE),
  Business:new(389, cp'Ломбард «Bargain LS»', {x = 975.286011, y = -1336.594971, z = 13.532000},GOOD_TYPE.NONE),
  Business:new(390, cp'Ломбард «Devil\'s Treasure»', {x = 2704.412109, y = -1095.608032, z = 69.454002},GOOD_TYPE.NONE),
  Business:new(391, cp'Ломбард «Been Flickin»', {x = -2549.745117, y = 296.033997, z = 18.221001},GOOD_TYPE.NONE),
  Business:new(392, cp'Ломбард «Dom\'s»', {x = -2157.100098, y = 159.559006, z = 35.320000},GOOD_TYPE.NONE),
  Business:new(393, cp'Ломбард «Android\'s Dungeon»', {x = -1617.640991, y = 1114.553955, z = 7.188000},GOOD_TYPE.NONE),
  Business:new(394, cp'Ломбард «Goldberg»', {x = 2085.666016, y = 2054.950928, z = 11.058000},GOOD_TYPE.NONE),
  Business:new(395, cp'Ломбард «Bargain LV»', {x = 2408.413086, y = 1996.766968, z = 10.820000},GOOD_TYPE.NONE),
  Business:new(396, cp'Ломбард «Katsenelenbogen»', {x = 2517.746094, y = 2334.618896, z = 10.820000},GOOD_TYPE.NONE),
  Business:new(397, cp'Автомастерская «Nick\'s Workshop»', {x = 1648.342041, y = -1506.545044, z = 13.547000},GOOD_TYPE.NONE),
  Business:new(398, cp'Автомастерская «Rudy\'s Workshop»', {x = -2110.629883, y = -2284.538086, z = 30.632000},GOOD_TYPE.NONE),
  Business:new(399, cp'Автомастерская «Michelle\'s Workshop»', {x = -1799.952026, y = 1200.378052, z = 25.118999},GOOD_TYPE.NONE),
  Business:new(400, cp'Автомастерская «Vario\'s Workshop»', {x = -2109.747070, y = 9.459000, z = 35.320000},GOOD_TYPE.NONE),
  Business:new(401, cp'Автомастерская «Roger\'s Workshop»', {x = 2432.210938, y = 121.095001, z = 26.469000},GOOD_TYPE.NONE),
  Business:new(402, cp'Автомастерская «Tommy\'s Workshop»', {x = 2510.211914, y = -1246.967041, z = 35.063000},GOOD_TYPE.NONE),
  Business:new(403, cp'Автомастерская «Jenny\'s Workshop»', {x = 2183.379883, y = 2495.037109, z = 10.820000},GOOD_TYPE.NONE),
  Business:new(404, cp'Автомастерская «Kenneth\'s Workshop»', {x = 2639.468018, y = 1065.598999, z = 10.820000},GOOD_TYPE.NONE),
  Business:new(405, cp'Автомастерская «Yorgan\'s Workshop»', {x = -256.199005, y = 1215.189941, z = 19.742001},GOOD_TYPE.NONE),
  Business:new(406, cp'Автомагазин «Yaiyarir Auto Parts #1»', {x = 908.294983, y = -1382.133057, z = 13.543000},GOOD_TYPE.AUTOPARTS),
  Business:new(407, cp'Автомагазин «Yaiyarir Auto Parts #2»', {x = 2473.052979, y = -1922.139038, z = 13.531000},GOOD_TYPE.AUTOPARTS),
  Business:new(408, cp'Автомагазин «Yaiyarir Auto Parts #3»', {x = -2339.186035, y = -27.372000, z = 35.320000},GOOD_TYPE.AUTOPARTS),
  Business:new(409, cp'Автомагазин «Yaiyarir Auto Parts #4»', {x = -1674.827026, y = 1238.586060, z = 7.242000},GOOD_TYPE.AUTOPARTS),
  Business:new(410, cp'Автомагазин «Yaiyarir Auto Parts #5»', {x = 2541.993896, y = 2284.854980, z = 10.820000},GOOD_TYPE.AUTOPARTS),
  Business:new(411, cp'Автомагазин «Yaiyarir Auto Parts #6»', {x = 2538.021973, y = 1153.868042, z = 10.822000},GOOD_TYPE.AUTOPARTS),
  Business:new(412, cp'Закусочная «Santa Flora»', {x = -2498.008057, y = 761.554993, z = 35.334000},GOOD_TYPE.PRODUCTS),
  Business:new(413, cp'Закусочная «Cluckin\' Bell #13»', {x = -2078.349121, y = 1341.837036, z = 7.186000},GOOD_TYPE.PRODUCTS),
  Business:new(414, cp'Секс-шоп «Nude & XXX #3»', {x = 953.945984, y = -1337.435059, z = 13.304000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(415, cp'Секс-шоп «Nude & XXX #4»', {x = 2408.416016, y = 2016.176025, z = 10.820000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(416, cp'Секс-шоп «XXX #3»', {x = 2213.464111, y = 1433.842041, z = 10.955000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(417, cp'Секс-шоп «XXX #4»', {x = 2420.340088, y = 2065.183105, z = 10.820000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(418, cp'Ресторан «Oriental»', {x = 1223.015991, y = -1129.828003, z = 23.997000},GOOD_TYPE.PRODUCTS),
  Business:new(419, cp'Ресторан «Calton»', {x = -1939.620972, y = 746.361023, z = 45.664001},GOOD_TYPE.PRODUCTS),
  Business:new(420, cp'Ресторан «Pastageddon»', {x = -2315.719971, y = -27.927000, z = 35.320000},GOOD_TYPE.PRODUCTS),
  Business:new(421, cp'Ресторан «Chinatown Plaza»', {x = 2634.758057, y = 1824.218994, z = 11.016000},GOOD_TYPE.PRODUCTS),
  Business:new(422, cp'Ресторан «Vice»', {x = 2489.976074, y = 2065.430908, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(423, cp'Ночной клуб «Azimuth»', {x = 2244.400879, y = 2525.071045, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(424, cp'Ночной клуб «Hashbury»', {x = -2489.864990, y = -142.772003, z = 25.617001},GOOD_TYPE.PRODUCTS),
  Business:new(425, cp'Секс-шоп «XXX #5»', {x = 2085.118896, y = 2074.048096, z = 11.055000},GOOD_TYPE.FUR_ELECTRONICS),
  Business:new(426, cp'Закусочная «Mexican Food #2»', {x = 1948.980957, y = -1985.051025, z = 13.547000},GOOD_TYPE.PRODUCTS),
  Business:new(427, cp'Закусочная «Venturas Steaks»', {x = 2369.240967, y = 1984.235962, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(428, cp'Тренировочный центр «US Firearms»', {x = 2264.948975, y = -2046.642944, z = 13.547000},GOOD_TYPE.WEAPONS),
  Business:new(429, cp'Тренировочный центр «AF Firearms»', {x = -2106.927002, y = -179.296005, z = 35.320000},GOOD_TYPE.WEAPONS),
  Business:new(430, cp'Тренировочный центр «RC Firearms»', {x = 2623.214111, y = 1207.115967, z = 10.820000},GOOD_TYPE.WEAPONS),
  Business:new(431, cp'Магазин «Old Venturas 24 / 7»', {x = 2452.525879, y = 2065.190918, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(432, cp'Мастерская «PAY N SPRAY #12»', {x = -2482.449951, y = -184.867004, z = 25.617001},GOOD_TYPE.AUTOPARTS),
  Business:new(433, cp'Арена «TFC US»', {x = 2246.877930, y = -2012.895996, z = 13.545000},GOOD_TYPE.PRODUCTS),
  Business:new(434, cp'Арена «TFC AF»', {x = -1866.525024, y = 943.362000, z = 35.172001},GOOD_TYPE.PRODUCTS),
  Business:new(435, cp'Арена «TFC RC»', {x = 1840.515015, y = 2155.241943, z = 10.920000},GOOD_TYPE.PRODUCTS),
  Business:new(436, cp'Бар «Stage Club Los Santos»', {x = 1325.051025, y = -1711.437988, z = 13.540000},GOOD_TYPE.PRODUCTS),
  Business:new(437, cp'Бар «Stage Club San Fierro»', {x = -2591.447021, y = 170.494003, z = 4.735000},GOOD_TYPE.PRODUCTS),
  Business:new(438, cp'Бар «Stage Club Las Venturas»', {x = 2597.789063, y = 1166.676025, z = 10.820000},GOOD_TYPE.PRODUCTS),
  Business:new(439, cp'Рыболовный магазин «Montgomery»', {x = 1205.826050, y = 338.683990, z = 20.017000},GOOD_TYPE.PRODUCTS),
  Business:new(440, cp'Рыболовный магазин «Angel Pine»', {x = -2057.389893, y = -2464.510010, z = 31.180000},GOOD_TYPE.PRODUCTS),
  Business:new(441, cp'Рыболовный магазин «El Quebrados»', {x = -1354.098999, y = 2057.680908, z = 53.117001},GOOD_TYPE.PRODUCTS),
  Business:new(442, cp'Студия звукозаписи «Blob Music»', {x = 1044.197021, y = -1291.363037, z = 13.777000},GOOD_TYPE.NONE),
  Business:new(443, cp'Студия звукозаписи «Fresh Records»', {x = -2099.596924, y = 635.460999, z = 52.367001},GOOD_TYPE.NONE),
  Business:new(444, cp'Студия звукозаписи «Sun Studio»', {x = 2515.763916, y = 1179.433960, z = 10.822000},GOOD_TYPE.NONE),
  Business:new(445, cp'Мастерская «Transfender LS»', {x = 1045.838989, y = -1026.438965, z = 32.102001},GOOD_TYPE.NONE),
  Business:new(446, cp'Мастерская «Transfender SF»', {x = -1942.942017, y = 238.477997, z = 34.313000},GOOD_TYPE.NONE),
  Business:new(447, cp'Мастерская «Transfender LV»', {x = 2393.282959, y = 1042.874023, z = 10.820000},GOOD_TYPE.NONE),
  Business:new(448, cp'Мастерская «Wheel Arch Angels»', {x = -2715.561035, y = 223.315994, z = 4.328000},GOOD_TYPE.NONE),
  Business:new(449, cp'Мастерская «Loco Low Co»', {x = 2652.905029, y = -2045.859985, z = 13.550000},GOOD_TYPE.NONE),
  Business:new(450, cp'Кафе «Hashbury Market»', {x = -2540.063965, y = -55.048000, z = 16.584000},GOOD_TYPE.PRODUCTS),
}
if not doesDirectoryExist(getWorkingDirectory() .. [[\config]]) then
  createDirectory(getWorkingDirectory() .. [[\config]])
end
if not doesDirectoryExist(getWorkingDirectory() .. [[\config\trinity-linerunner]]) then
  createDirectory(getWorkingDirectory() .. [[\config\trinity-linerunner]])
end
local businesses_filepath = getWorkingDirectory() .. [[\config\trinity-linerunner\businesses.json]]
---Saves businesses to file in JSON format
---@param businesses business[]
local function save_businesses(businesses)
  local bs = {}
  for _, b in ipairs(businesses) do table.insert(bs, b:to_json()) end
  local f = assert(io.open(businesses_filepath, 'w'), 'Failed to open file')
  f:write(encodeJson(bs))
  f:close()
end
---Loads businesses from file in JSON format
---Returns nil if file doesn't exist
---Returned list might be empty if file is empty or contains invalid data (e.g. not a list of businesses)
---Returned businesses are sorted by idx
---@return business[]?
local function load_businesses()
  local f = io.open(businesses_filepath, 'r')
  if not f then return nil end
  local bs = decodeJson(f:read('*a'))
  f:close()

  local businesses = {}
  for _, b in ipairs(bs) do table.insert(businesses, Business:new(b.idx, b.name, {x = b.position.x, y = b.position.y, z = b.position.z}, GoodType.from_string(b.good_type))) end
  table.sort(businesses, function(a, b) return a.idx < b.idx end)
  return businesses
end
---@type business[]
local supplied_businesses = {}
for _, business in pairs(businesses) do
  if business.good_type ~= GOOD_TYPE.NONE then
    table.insert(supplied_businesses, business)
  end
end
---@type table<business, integer>
local recent_businesses = {}
---Returns nearest business to the position
---@param businesses business[]
---@param position position
---@param max_dist integer
---@return business?
local function get_nearest_business(businesses, position, max_dist)
  local nearest_business = nil ---@type business?
  local min_dist = math.huge

  for _, b in ipairs(businesses) do
    local dist = b:distance_to(position)
    if dist <= max_dist and dist <= min_dist then
      nearest_business = b
      min_dist = dist
    end
  end
  return nearest_business
end
---@class vehicle_trunk : table<good_type, integer>
local VehicleTrunk = {
  [GOOD_TYPE.PRODUCTS] = 0,
  [GOOD_TYPE.FUR_ELECTRONICS] = 0,
  [GOOD_TYPE.AUTOPARTS] = 0,
  [GOOD_TYPE.WEAPONS] = 0,
  [GOOD_TYPE.CLOTHES] = 0,
  [GOOD_TYPE.MEDICINES] = 0,
}
---@param vt vehicle_trunk?
---@return vehicle_trunk
function VehicleTrunk:new(vt)
  vt = vt or {}
  setmetatable(vt, self)
  self.__index = self
  return vt
end
---@type vehicle_trunk
local vehicle_trunk = VehicleTrunk:new({})
---@class route
---@field business business
---@type route[]
local routes = {}
---Calculates fulfillable routes based on provided vehicle trunk
---@param routes route[]
---@param vehicle_trunk vehicle_trunk
---@return route[]
local function get_fulfillable_routes(routes, vehicle_trunk)
  local fulfillable_routes = {} ---@type route[]
  local leftover_goods = {} ---@type vehicle_trunk
  for good_type, quantity in pairs(vehicle_trunk) do
    leftover_goods[good_type] = quantity
  end
  for _, route in ipairs(routes) do
    local business = route.business
    local good_type = business.good_type
    local good_quantity = business.required_goods
    local quantity_to_buy = math.min(good_quantity or 0, leftover_goods[good_type] or 0)
    if quantity_to_buy > 0 then
      leftover_goods[good_type] = leftover_goods[good_type] - quantity_to_buy
      table.insert(fulfillable_routes, {business = business})
    end
  end
  return fulfillable_routes
end
--- @param text string | number Text to print
--- @param color number? Color of the message (default: -1 (white))
local function alert(text, color)
  color = color or -1
  sampAddChatMessage('[TLR]: '..text, color)
end
---Calculates required goods of each type until vehicle trunk is full or all routes are fulfilled
---@param routes route[]
---@param ignored_good_types set<good_type>
---@param vehicle_trunk_size integer
---@return vehicle_trunk
local function get_required_goods(routes, ignored_good_types, vehicle_trunk_size)
  local total_quantity = 0 ---@type integer Total quantity of goods to buy
  local required_goods = VehicleTrunk:new()
  local route_idx = 1
  while total_quantity < vehicle_trunk_size and route_idx <= #routes do
    local business = routes[route_idx].business
    local good_type = business.good_type
    if not ignored_good_types:has(good_type) then
      local good_quantity = business.required_goods
      local quantity_to_buy = math.min(good_quantity or 0, vehicle_trunk_size - total_quantity)
      -- alert('I am going to buy '..quantity_to_buy..' '..good_type.name..' due to '..business.name..' ('..good_quantity..' requires, '..vehicle_trunk_size-total_quantity..' free space in the trunk)')
      required_goods[good_type] = (required_goods[good_type] or 0) + quantity_to_buy
      total_quantity = total_quantity + quantity_to_buy
    end
    route_idx = route_idx + 1
  end
  required_goods[GOOD_TYPE.PRODUCTS] = required_goods[GOOD_TYPE.PRODUCTS] + (vehicle_trunk_size - total_quantity)
  return required_goods
end
---Calculates goods to buy based on vehicle trunk and required goods
---@param vehicle_trunk vehicle_trunk
---@param required_goods vehicle_trunk
---@return vehicle_trunk
local function get_goods_to_buy(vehicle_trunk, required_goods)
  local goods_to_buy = {} ---@type vehicle_trunk
  for good_type, quantity in pairs(required_goods) do
    goods_to_buy[good_type] = quantity - vehicle_trunk[good_type]
  end
  return goods_to_buy
end

local overlay = {
  show = new.bool(false),
  sell_only_routes = new.bool(false),
  ignore_weapons = new.bool(true),
  auto_sell = new.bool(true)
}
function sampev.onShowDialog(dialog_id, style, title, button1, button2, text)
  if dialog_id == DIALOG.ROUTES then
    routes = {}
    local i = 0
    for row in text:gmatch('[^\r\n]+') do
      if i ~= 0 then
        local business_name, good_quantity, good_type, price = row:match(cp'(.-)\t{D8A903}(%d+){ffffff} ед.\t{abcdef}(.-)\t{33aa33}(%d+) %$')
        assert(business_name ~= nil and good_quantity ~= nil)
        local business = nil ---@type business?
        for _, b in ipairs(supplied_businesses) do
          if b.name == business_name then
            business = b
            break
          end
        end
        assert(business ~= nil)
        business.required_goods = tonumber(good_quantity)
        table.insert(routes, {business = business})
      end
      i = i + 1
    end
    return
  elseif dialog_id == DIALOG.GOODS_LIST then
    local goods_to_buy = get_goods_to_buy(vehicle_trunk, get_required_goods(routes, Set:new({overlay.ignore_weapons[0] and GOOD_TYPE.WEAPONS or nil}), 3000))
    local has_goods_to_return = false
    for _, quantity in pairs(goods_to_buy) do
      if quantity < 0 then has_goods_to_return = true break end
    end
    if has_goods_to_return then
      alert('Some goods needs to be returned')
      sampSendDialogResponse(dialog_id, 0, 0, '')
      sampSendChat('/returnprods')
      return false
    end
    for good_type, quantity in pairs(goods_to_buy) do
      if quantity > 0 then
        alert('Buying '..quantity..' '..good_type.name)
        sampSendDialogResponse(dialog_id, 1, good_type.position, good_type.name)
        return false
      end
    end
    sampSendDialogResponse(dialog_id, 0, 0, '')
    for _, route in ipairs(get_fulfillable_routes(routes, vehicle_trunk)) do route.business:create_blip() end
    return false
  elseif dialog_id == DIALOG.GOODS_QUANTITY then
    local goods_to_buy = get_goods_to_buy(vehicle_trunk, get_required_goods(routes, Set:new({overlay.ignore_weapons[0] and GOOD_TYPE.WEAPONS or nil}), 3000))
    local good_type = GoodType.from_string(text:match(cp'Закупаемый товар:.-{D8A903}(.-)\n'))
    local quantity = goods_to_buy[good_type] or 0
    if quantity > 0 then
      alert('Buying '..quantity..' '..good_type.name)
      sampSendDialogResponse(dialog_id, 1, 0, tostring(quantity))
      return false
    end
    return
  elseif dialog_id == DIALOG.GOODS_CONFIRM then
    local good_type = GoodType.from_string(text:match(cp'Закупаемый товар:.-{D8A903}(.-)\n')) or GOOD_TYPE.NONE
    local quantity = tonumber(text:match(cp'Закупаемое количество:.-{F5DEB3}(%d+){abcdef}\n')) or 0
    if good_type ~= GOOD_TYPE.NONE and quantity > 0 then
      alert('Bought '..quantity..' '..good_type.name)
      vehicle_trunk[good_type] = vehicle_trunk[good_type]+quantity
      sampSendDialogResponse(dialog_id, 1, -1, '')
      sampSendChat('/buyprods')
      return false
    end
    return
  elseif dialog_id == DIALOG.GOODS_RETURN then
    for _, good_type in pairs(GOOD_TYPE) do
      vehicle_trunk[good_type] = nil
      -- Мебель и электроника 	{d8a903}548{ffffff} шт.
      local quantity =  text:match(good_type.name..'.-{d8a903}(%d+)')
      if quantity then vehicle_trunk[good_type] = tonumber(quantity) end
    end

    return false
  elseif dialog_id == DIALOG.GOODS_RETURN_CONFIRM then
    sampSendDialogResponse(dialog_id, 1, 0, '')
    return false
  elseif dialog_id == DIALOG.GOODS_SELL then
    sampSendDialogResponse(dialog_id, 1, -1, '')
    return false
  elseif dialog_id == DIALOG.INFORMATION then
    if text == cp'{9ACD32}Управляющий: Наш склад заполнен. Нам не требуется поставка товара.' then
      local x, y, z = getCharCoordinates(PLAYER_PED)
      local business = get_nearest_business(businesses, {x = x, y = y, z = z}, 20)
      if business ~= nil then
        business:remove_blip()
        recent_businesses[business] = os.time() + 5*60
        business.required_goods = 0
      end
      alert('No need to supply')
      sampSendDialogResponse(dialog_id, 1, -1, '')
      return false
    elseif text == cp'{9ACD32}Управляющий: Отправляйтесь к зоне доставки. Посмотрим что у вас есть.' then
      sampSendDialogResponse(dialog_id, 1, -1, '')
      alert('Go to the delivery zone')
      return false
    elseif text == cp'{9ACD32}В вашем транспорте нет товаров, которые мы могли бы купить у вас.' then
      sampSendDialogResponse(dialog_id, 1, -1, '')
      alert('No goods to sell')
      vehicle_trunk = VehicleTrunk:new()
      return false
    elseif text:find(cp'{ffffff}Товар успешно загружен. Команда {D8A903}/route{ffffff} поможет вам найти предприятие, которое купит товар у вас.') then
      sampSendDialogResponse(dialog_id, 1, -1, '')
      return false
    elseif title:find(cp'{ffffff}Предметы, хранящиеся в {F5DEB3}.+') then
      for _, good_type in pairs(GOOD_TYPE) do
        vehicle_trunk[good_type] = nil
        local quantity = text:match('{ffffff}'..good_type.name..' {abcdef}%[(%d+)')
        if quantity then vehicle_trunk[good_type] = tonumber(quantity) end
      end
      -- for line in text:gmatch('[^\r\n]+') do
      --   local good_type, quantity = line:match(cp'{ffffff}(.-) {abcdef}%[(%d+) ед%]')
      --   if good_type ~= nil and quantity ~= nil then
      --     vehicle_trunk[GoodType.from_string(good_type)] = tonumber(quantity)
      --   end
      -- end
    end
    local good_type, quantity = text:match(cp'{ffffff}Вы успешно вернули на склад {abcdef}(.-){ffffff} в количестве {D8A903}(%d-){ffffff} штук.? и получили за это {33aa33}%d+ %${ffffff}.')
    if good_type ~= nil and quantity ~= nil then
      vehicle_trunk[GoodType.from_string(good_type)] = 0
      return false
    end
    local business_name, good_quantity, good_type, price = text:match(cp'{ffffff}Предприятие {ffff00}(.-){ffffff} купило у вас {D8A903}(.-){ffffff} ед%. {abcdef}(.-){ffffff} за {33aa33}(.-) ${ffffff}.')
    if business_name ~= nil and good_quantity ~= nil and good_type ~= nil and price ~= nil then
      local business = nil ---@type business?
      for _, b in ipairs(supplied_businesses) do
        if b.name == business_name then
          business = b
          break
        end
      end
      assert(business ~= nil)
      local sold_good_type = GoodType.from_string(good_type)
      alert('Sold '..good_quantity..' '..sold_good_type.name..' to '..business.name..' for '..price..'$')
      vehicle_trunk[sold_good_type] = math.max(vehicle_trunk[sold_good_type] - tonumber(good_quantity), 0)
      business.required_goods = math.max((business.required_goods or 0) - tonumber(good_quantity), 0)
      business:remove_blip()
      recent_businesses[business] = os.time() + 5*60
      sampSendDialogResponse(dialog_id, 1, -1, '')
      return false
    end
    return
  end
end

-- function sampev.onSendDialogResponse(dialog_id, button, listbox_id, input)
--   print('onSendDialogResponse', dialog_id, button, listbox_id, input)
-- end

function sampev.onServerMessage(color, text)
  if text == cp'Администрация проекта благодарит вас за то, что вы остаетесь с нами.' then
    for _, business in ipairs(supplied_businesses) do
      business.required_goods = (business.required_goods or 0) + 50
    end
    recent_businesses = {}
    return
  end
  if color == -1347440641 and text == cp'В багажном отделении ничего нет.'
  or color == -660012033 and text:find(cp'Вам возвращена сумма в {33aa33}%d+ %${D8A903} за товары из грузового отсека%.') then
    vehicle_trunk = VehicleTrunk:new()
    return
  end
end
---
---@param business business
---@param distance number
---@param vehicle_trunk vehicle_trunk
function imgui.Business(business, distance, vehicle_trunk)
  local name = u8(business.name)
  local good_type = business.good_type
  local good_quantity = vehicle_trunk[business.good_type]

  if imgui.Checkbox(string.format('%s (%d m) - %s (%d/%s)', name, distance, u8(good_type.name), good_quantity, business.required_goods or '?'), business.blip_shown) then
    if business.blip_shown[0] then business:create_blip() else business:remove_blip() end
  end
end

imgui.OnFrame(
  function () return overlay.show[0] end,
  function (player)
    local flags = --[[ imgui.WindowFlags.NoDecoration + ]] imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoSavedSettings
    local io = imgui.GetIO()
    -- assert(io, 'Error getting imgui IO')
    player.HideCursor = true
    imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x, io.DisplaySize.y), imgui.Cond.Always, imgui.ImVec2(1, 1))

    imgui.Begin("Overlay", nil, flags)
    imgui.Checkbox('Продавать только по маршрутам', overlay.sell_only_routes)
    imgui.SameLine()
    imgui.Checkbox('Игнорировать оружие', overlay.ignore_weapons)
    imgui.Checkbox('Автопродажа', overlay.auto_sell)
    imgui.Text('Ближайшие предприятия:')
    local shown = Set:new()
    local businesses_to_show = {} ---@type business[]
    local x, y, z = getCharCoordinates(PLAYER_PED)
    local distances = {} ---@type {dist: number, business: business}[]
    for _, business in pairs(supplied_businesses) do
      table.bininsert(distances, {dist = business:distance_to({x = x, y = y, z = z}), business = business}, function(a, b) return a.dist < b.dist end)
    end

    local i = 1
    while not overlay.sell_only_routes[0] and i < #distances and shown:size() < 10  do
      local business = distances[i].business
      if business.required_goods ~= 0 and vehicle_trunk[business.good_type] > 0 then
        shown:add(business)
        table.bininsert(businesses_to_show, business, function(a, b) return a:distance_to({x = x, y = y, z = z}) < b:distance_to({x = x, y = y, z = z}) end)
      end
      i = i + 1
    end

    for _, business in pairs(supplied_businesses) do
      if business.blip_shown[0] and not shown:has(business) then
        shown:add(business)
        table.bininsert(businesses_to_show, business, function(a, b) return a:distance_to({x = x, y = y, z = z}) < b:distance_to({x = x, y = y, z = z}) end)
      end
    end
    for _, business in ipairs(businesses_to_show) do
      imgui.PushIDStr('supplied')
      imgui.Business(business, business:distance_to({x = x, y = y, z = z}), vehicle_trunk)
      imgui.PopID()
    end
    imgui.Text('Заказы:')
    for _, route in pairs(routes) do
      local business = route.business
      imgui.PushIDStr('route')
      imgui.Business(business, business:distance_to({x = x, y = y, z = z}), vehicle_trunk)
      imgui.PopID()
    end
    imgui.Separator()
    local total_count = 0
    local required_goods = get_required_goods(routes, Set:new({overlay.ignore_weapons[0] and GOOD_TYPE.WEAPONS or nil}), 3000)
    local total_required = 0
    for _, v in pairs(required_goods) do
      total_required = total_required + v
    end
    for k, v in pairs(vehicle_trunk) do
      imgui.Text(string.format('%s: %d (%d required)', u8(k.name), v, required_goods[k] or 0))
      total_count = total_count + v
    end
    imgui.Text(string.format('Total: %d (%d required)', total_count, total_required))
    imgui.End()
  end
)

local function recent_businesses_cleanup()
  while true do
    for business, deadline in pairs(recent_businesses) do
      if deadline < os.time() then
        recent_businesses[business] = nil
      end
    end
    wait(1 * 60 * 1000)
  end
end

local speed_multiplier = 1.4

function sampev.onSendVehicleSync(data)
  if overlay.auto_sell[0] and isCharInModel(PLAYER_PED, VEHICLE_MODEL.YANKEE) then
    -- local move_speed = math.sqrt(data.moveSpeed.x^2 + data.moveSpeed.y^2 + data.moveSpeed.z^2) * speed_multiplier * 100
    local business_next = get_nearest_business(businesses, {
      x = data.position.x + data.moveSpeed.x,
      y = data.position.y + data.moveSpeed.y,
      z = data.position.z + data.moveSpeed.z
    }, 19)
    local business_cur = get_nearest_business(businesses, {x = data.position.x, y = data.position.y, z = data.position.z}, 19)
    local business_prev = get_nearest_business(businesses, {
      x = data.position.x - data.moveSpeed.x,
      y = data.position.y - data.moveSpeed.y,
      z = data.position.z - data.moveSpeed.z
    }, 19)
    if business_next ~= nil
      and business_next == business_cur
      and business_cur == business_prev
      and recent_businesses[business_next] == nil
      and business_next.good_type ~= GOOD_TYPE.NONE then
      for i, route in ipairs(routes) do
        if not overlay.sell_only_routes[0] or route.business == business_next then
          local good_type = business_next.good_type
          local quantity = vehicle_trunk[good_type]
          if quantity > 0 then
            alert('Selling '..quantity..' '..good_type.name)
            recent_businesses[business_next] = os.time() + 5 * 60
            sampSendChat('/sellprods')
            return
          end
        end
      end
    end
  end
end
function onExitScript()
  for _, business in pairs(businesses) do
    business:remove_blip()
  end
  save_businesses(businesses)
end
function sampev.onCreate3DText(id, color, pos, distance, test, attachedPlayer, attachedVehicle, text)
  local idx, name = text:match(cp'Частное предприятие {abcdef}#(%d+).-\n{fbec5d}(.-)\n')
  if idx and name then
    idx = tonumber(idx) or 0 ---@type integer

    local business = nil ---@type business?
    for _, b in ipairs(businesses) do
      if b.idx == tonumber(idx) then
        business = b
        break
      end
    end

    if business == nil then
      business = Business:new(idx, name, {x = pos.x, y = pos.y, z = pos.z}, GOOD_TYPE.NONE)
      table.insert(businesses, business)
      alert('New business '..business.name..' created')
      print('New business '..business.name..' created')
      print(inspect(business))
      return
    end

    if business.name ~= name then
      alert('Business '..business.name..' name mismatch: '..name)
      print('Business '..business.name..' name mismatch: '..name)
      print(inspect(business))
      business.name = name
    end

    local eps = 0.001
    if business.position.x ~= pos.x or business.position.y ~= pos.y or business.position.z ~= pos.z then
      if math.abs(business.position.x - pos.x) > eps or math.abs(business.position.y - pos.y) > eps or math.abs(business.position.z - pos.z) > eps then
        alert('Business '..business.name..' position mismatch: '..pos.x..', '..pos.y..', '..pos.z)
        print('Business '..business.name..' position mismatch: '..pos.x..', '..pos.y..', '..pos.z)
        print(inspect(business))
        business.position = {x = pos.x, y = pos.y, z = pos.z}
      end
    end
  end
  -- print(text, pos.x, pos.y, pos.z)
end
function main()
  if not isSampfuncsLoaded() or not isSampLoaded() then return end
  while not isSampAvailable() do wait(1000) end

  local bs = load_businesses()
  if not bs then save_businesses(businesses)
  else businesses = bs
  end

  sampRegisterChatCommand('tlr', function() overlay.show[0] = not overlay.show[0] end)

  -- lua_thread.create(recent_businesses_cleanup)
  recent_businesses_cleanup()
end