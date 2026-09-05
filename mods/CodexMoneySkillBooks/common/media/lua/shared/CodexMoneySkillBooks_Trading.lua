CodexMoneySkillBooksTrading = CodexMoneySkillBooksTrading or {}

local TOYS = {
    ["Base.Bricktoys"] = true,
    ["Base.CardDeck"] = true,
    ["Base.CatToy"] = true,
    ["Base.Crayons"] = true,
    ["Base.Cube"] = true,
    ["Base.Dice"] = true,
    ["Base.DogChew"] = true,
    ["Base.Doll"] = true,
    ["Base.RubberSpider"] = true,
    ["Base.ToyBear"] = true,
    ["Base.ToyBear_Crafted_Cotton"] = true,
    ["Base.ToyBear_Crafted_Burlap"] = true,
    ["Base.ToyCar"] = true,
    ["Base.ToyPlane"] = true,
    ["Base.Yoyo"] = true,
}

function CodexMoneySkillBooksTrading.isSellableMemento(item)
    if not item or not item.getFullType then
        return false
    end

    local fullType = item:getFullType()
    if TOYS[fullType] == true then
        return false
    end

    local itemType = string.lower(item:getType() or "")
    if string.find(itemType, "idcard", 1, true) or itemType == "pressid" then
        return false
    end

    if item.hasTag and ItemTag and ItemTag.IDCARD and item:hasTag(ItemTag.IDCARD) then
        return false
    end

    return true
end
