// Vehicle.java

public class Main{
    public static void main(String[] args) {
        VehicleManager vehicleManager = new VehicleManager();

        try {
            Car car1 = new Car("BMW", "420i", 2020, 5);
            vehicleManager.addVehicle(car1);

            Motorcycle motorcycle1 = new Motorcycle("yamaha", "ninja", 2020, true);
            vehicleManager.addVehicle(motorcycle1);


            vehicleManager.printAllVehicles();

            Vehicle foundVehicle =vehicleManager.searchVehicle("BMW", "420i");
            System.out.println("Found Vehicle: " + foundVehicle);

            vehicleManager.removeVehicle(car1);
            vehicleManager.printAllVehicles();

            Vehicle duplicateCar1 = new Car("nissan", "GTR", 2020, 5);
            vehicleManager.addVehicle(duplicateCar1); // 중복 예외 발생

           Vehicle duplicateCar2 = new Car("nissan", "GTR", 2020, 5);
           vehicleManager.addVehicle(duplicateCar2); // 중복 예외 발생

            // 여러 오류 검사 코드 주석으로 해볼 수 있음

            //vehicleManager.searchVehicle("Ford", "Mustang"); // VehicleNotFoundException 발생
            //Car invalidCar = new Car("hyundai", "gv80", 2024, 0); // InvalidVehicleDetailException 발생

        } catch (DuplicateVehicleException e)
        {
            System.out.println("Duplicate Vehicle Error: " + e.getMessage());
        } catch (VehicleNotFoundException e)
        {
            System.out.println("Vehicle Not Found Error: " + e.getMessage());
        } catch (InvalidVehicleDetailException e)
        {
            System.out.println("Invalid Vehicle Detail Error: " + e.getMessage());
        } catch (Exception e)
        {
            System.out.println("Error: " + e.getMessage());
        }
    }
}
